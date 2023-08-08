// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IJBController3_1} from "@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBController3_1.sol";
import {IJBPayoutRedemptionPaymentTerminal3_1_1} from
    "@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBPayoutRedemptionPaymentTerminal3_1_1.sol";
import {IJBDirectory} from "@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBDirectory.sol";
import {IJBFundingCycleDataSource3_1_1} from
    "@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBFundingCycleDataSource3_1_1.sol";
import {IJBPayDelegate3_1_1} from "@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBPayDelegate3_1_1.sol";
import {IJBPaymentTerminal} from "@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBPaymentTerminal.sol";
import {IJBSingleTokenPaymentTerminal} from
    "@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBSingleTokenPaymentTerminal.sol";

import {JBTokens} from "@jbx-protocol/juice-contracts-v3/contracts/libraries/JBTokens.sol";

import {JBDidPayData3_1_1} from "@jbx-protocol/juice-contracts-v3/contracts/structs/JBDidPayData3_1_1.sol";
import {JBPayParamsData} from "@jbx-protocol/juice-contracts-v3/contracts/structs/JBPayParamsData.sol";
import {JBRedeemParamsData} from "@jbx-protocol/juice-contracts-v3/contracts/structs/JBRedeemParamsData.sol";
import {JBPayDelegateAllocation3_1_1} from
    "@jbx-protocol/juice-contracts-v3/contracts/structs/JBPayDelegateAllocation3_1_1.sol";
import {JBRedemptionDelegateAllocation3_1_1} from
    "@jbx-protocol/juice-contracts-v3/contracts/structs/JBRedemptionDelegateAllocation3_1_1.sol";

import {JBDelegateMetadataHelper} from "@jbx-protocol/juice-delegate-metadata-lib/src/JBDelegateMetadataHelper.sol";

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {ERC165, IERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {mulDiv18} from "@prb/math/src/Common.sol";

import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3SwapCallback} from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";

import {OracleLibrary} from "@uniswap/v3-periphery/contracts/libraries/OracleLibrary.sol";

import {IWETH9} from "./interfaces/external/IWETH9.sol";

/**
 * @custom:benediction DEVS BENEDICAT ET PROTEGAT CONTRACTVS MEAM
 *
 * @title  Generic Buyback Delegate compatible with any jb terminal
 *
 * @notice Datasource and delegate allowing pay beneficiary to get the highest amount
 *         of project tokens between minting using the project weigh and swapping in a
 *         given Uniswap V3 pool
 *
 * @dev    This supports any terminal and token, as well as any number of projects using it.
 */

contract JBGenericBuybackDelegate is
    Ownable,
    ERC165,
    JBDelegateMetadataHelper,
    IJBFundingCycleDataSource3_1_1,
    IJBPayDelegate3_1_1,
    IUniswapV3SwapCallback
{
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error JuiceBuyback_Unauthorized();
    error JuiceBuyback_MaximumSlippage();
    error JuiceBuyback_NewSecondsAgoTooLow();
    error JuiceBuyback_TransferFailed();

    //*********************************************************************//
    // -----------------------------  events ----------------------------- //
    //*********************************************************************//

    event BuybackDelegate_Swap(uint256 indexed projectId, uint256 amountEth, uint256 amountOut);
    event BuybackDelegate_Mint(uint256 indexed projectId);
    event BuybackDelegate_SecondsAgoChanged(uint256 indexed projectId, uint256 oldSecondsAgo, uint256 newSecondsAgo);
    event BuybackDelegate_TwapDeltaChanged(uint256 indexed projectId, uint256 oldTwapDelta, uint256 newTwapDelta);
    event BuybackDelegate_PendingSweep(address indexed beneficiary, uint256 amount);
    event BuybackDelegate_PoolAdded(uint256 indexed projectId, IERC20 indexed terminalToken, address newPool);

    //*********************************************************************//
    // --------------------- private constant properties ----------------- //
    //*********************************************************************//
    /**
     * @notice The unit of the max slippage (expressed in 1/10000th)
     */
    uint256 constant SLIPPAGE_DENOMINATOR = 10000;

    address immutable UNISWAP_V3_FACTORY;

    /**
     * @notice The JB Directory
     */
    IJBDirectory public immutable DIRECTORY;

    /**
     * @notice The project controller
     */
    IJBController3_1 public immutable CONTROLLER;

    /**
     * @notice The WETH contract
     */
    IWETH9 public immutable WETH;

    /**
     * @notice The 4bytes ID of this delegate, used for metadata parsing
     */

    bytes4 public immutable delegateId;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /**
     * @notice The uniswap pool corresponding to the project token-terminal token market
     *         (this should be carefully chosen liquidity wise)
     */
    mapping(uint256 _projectId => mapping(IERC20 _terminalToken => IUniswapV3Pool _pool)) public poolOf;

    // the timeframe to use for the pool twap (from secondAgo to now)
    mapping(uint256 _projectId => uint32 _seconds) public secondsAgoOf;

    // the twap max deviation acepted (in 10_000th)
    mapping(uint256 _projectId => uint256 _delta) public twapDeltaOf;

    // the project token
    mapping(uint256 _projectId => IERC20 projectTokenOf) public projectTokenOf;

    // any ETH left-over in this contract (from swap in the end of liquidity range)
    mapping(address _beneficiary => mapping(IERC20 _token => uint256 _balance)) public sweepBalanceOf;

    // running cumulative sum of ETH left-over
    mapping(address _token => uint256 _contractBalance) public unclaimedSweepBalanceOf;

    //*********************************************************************//
    // ---------------------------- Constructor -------------------------- //
    //*********************************************************************//

    /**
     * @dev No other logic besides initializing the immutables
     */
    constructor(
        IWETH9 _weth,
        address _factory,
        IJBDirectory _directory,
        IJBController3_1 _controller,
        bytes4 _delegateId
    ) {
        WETH = _weth;
        DIRECTORY = _directory;
        CONTROLLER = _controller;
        UNISWAP_V3_FACTORY = _factory;
        delegateId = _delegateId;
    }

    // Act as a default pool for a given project - use create2 for callback auth
    function setPoolFor(uint256 _projectId, uint24 _fee, uint32 _secondsAgo, uint256 _twapDelta, address _terminalToken)
        external
        onlyOwner
    {
        // Get the project token
        IERC20 _projectToken = CONTROLLER.tokenStore().tokenOf(_projectId);

        bool _projectTokenIs0 = address(_projectToken) < _terminalToken;

        // Compute the corresponding pool
        IUniswapV3Pool _newPool = IUniswapV3Pool(
            address(
                uint160(
                    uint256(
                        keccak256(
                            abi.encodePacked(
                                hex"ff",
                                UNISWAP_V3_FACTORY,
                                keccak256(
                                    abi.encode(
                                        _projectTokenIs0 ? _projectToken : _terminalToken,
                                        _projectTokenIs0 ? _terminalToken : _projectToken,
                                        _fee
                                    )
                                ),
                                bytes32(0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54)
                            )
                        )
                    )
                )
            )
        );

        // Store the twap period and max slippage
        secondsAgoOf[_projectId] = _secondsAgo;
        twapDeltaOf[_projectId] = _twapDelta;
        projectTokenOf[_projectId] = _projectToken;

        // Store the pool
        poolOf[_projectId][_terminalToken] = _newPool;

        emit BuybackDelegate_SecondsAgoIncrease(_projectId, 0, _secondsAgo);
        emit BuybackDelegate_TwapDeltaChanged(_projectId, 0, _twapDelta);
        emit BuybackDelegate_PoolAdded(_projectId, _terminalToken, address(_newPool));
    }

    //*********************************************************************//
    // ---------------------- external functions ------------------------- //
    //*********************************************************************//

    /**
     * @notice The datasource implementation
     *
     * @param  _data the data passed to the data source in terminal.pay(..). _data.metadata need to have the Uniswap quote
     *               this quote should be set as 0 if the user wants to use the vanilla minting path
     * @return weight the weight to use (the one passed if not max reserved rate, 0 if swapping or the one corresponding
     *         to the reserved token to mint if minting)
     * @return memo the original memo passed
     * @return delegateAllocations The amount to send to delegates instead of adding to the local balance.
     */
    function payParams(JBPayParamsData calldata _data)
        external
        view
        override
        returns (uint256 weight, string memory memo, JBPayDelegateAllocation3_1_1[] memory delegateAllocations)
    {
        // Find the total number of tokens to mint, as a fixed point number with 18 decimals
        uint256 _tokenCount = mulDiv18(_data.forwardedAmount.value, _data.weight);

        // Get a quote based on either the uni SDK quote or a twap from the pool
        uint256 _swapAmountOut;

        (bool _validQuote, bytes memory _metadata) = getMetadata(delegateId, _data.metadata);

        uint256 _quote;
        uint256 _slippage;
        if (_validQuote) (_quote, _slippage) = abi.decode(_metadata, (uint256, uint256));

        IERC20 _projectToken = projectTokenOf(_data.projectId);

        if (_quote != 0) {
            // Unpack the quote from the pool, given by the frontend - this one takes precedence on the twap
            // as it should be closer to the current pool state, if not, use the twap
            _swapAmountOut = _quote - ((_quote * _slippage) / SLIPPAGE_DENOMINATOR);
        } else {
            _swapAmountOut = _getQuote(_data.projectId, _data.terminal, _projectToken, _data.forwardedAmount.value);
        }

        // If the minimum amount received from swapping is greather than received when minting, use the swap pathway
        if (_tokenCount < _swapAmountOut) {
            // Return this delegate as the one to use, along the quote and reserved rate, and do not mint from the terminal
            delegateAllocations = new JBPayDelegateAllocation3_1_1[](1);
            delegateAllocations[0] = JBPayDelegateAllocation3_1_1({
                delegate: IJBPayDelegate3_1_1(this),
                amount: _data.forwardedAmount.value,
                metadata: abi.encode(_tokenCount, _swapAmountOut, _projectToken)
            });

            return (0, _data.memo, delegateAllocations);
        }

        // If minting, do not use this as delegate (delegateAllocations is left uninitialised)
        return (_data.weight, _data.memo, delegateAllocations);
    }

    /**
     * @notice Delegate to either swap to the beneficiary or mint to the beneficiary
     *
     * @dev    This delegate is called only if the quote for the swap is bigger than the lowest received when minting.
     *         If the swap reverts (slippage, liquidity, etc), the delegate will then mint the same amount of token as
     *         if the delegate was not used.
     *         If the beneficiary requests non claimed token, the swap is not used (as it is, per definition, claimed token)
     *
     * @param _data the delegate data passed by the terminal
     */
    function didPay(JBDidPayData3_1_1 calldata _data) external payable override {
        // Access control as minting is authorized to this delegate
        if (!DIRECTORY.isTerminalOf(_data.projectId, IJBPaymentTerminal(msg.sender))) {
            revert JuiceBuyback_Unauthorized();
        }

        (uint256 _tokenCount, uint256 _swapMinAmountOut, IERC20 _projectToken) =
            abi.decode(_data.dataSourceMetadata, (uint256, uint256, IERC20));

        // Try swapping
        uint256 _amountReceived = _swap(_data, _swapMinAmountOut, _projectToken);

        // If swap failed, mint instead, with the original weight + add to balance the token in
        if (_amountReceived == 0) _mint(_data, _tokenCount);

        // Track any new eth left-over
        uint256 _terminalTokenInThisContract = _data.forwardedAmount.token == JBTokens.ETH
            ? address(this).balance
            : IERC20(_data.forwardedAmount.token).balanceOf(address(this));
        uint256 _terminalTokenPreviouslyInThisContract = unclaimedSweepBalanceOf[_data.forwardedAmount.token];
        uint256 _beneficiarySweepBalance = sweepBalanceOf[_data.beneficiary][_data.forwardedAmount.token];

        if (_terminalTokenInThisContract > 0 && _terminalTokenInThisContract != _beneficiarySweepBalance) {
            sweepBalanceOf[_data.beneficiary][_data.forwardedAmount.token] +=
                _terminalTokenInThisContract - _terminalTokenPreviouslyInThisContract;

            emit BuybackDelegate_PendingSweep(
                _data.beneficiary,
                _terminalTokenInThisContract - sweepBalanceOf[_data.beneficiary][_data.forwardedAmount.token]
            );

            unclaimedSweepBalanceOf[_data.forwardedAmount.token] = _terminalTokenInThisContract;
        }
    }

    /**
     * @notice The Uniswap V3 pool callback (where token transfer should happens)
     *
     * @dev    Slippage controle is achieved here
     */
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external override {
        // Unpack the data
        (uint256 _projectId, uint256 _minimumAmountReceived, address _terminalToken, address _projectToken) =
            abi.decode(data, (uint256, uint256, address, address));

        // Check if this is really a callback - only create2 pools are added to insure safety of this check (balance pending sweep at risk)
        if (msg.sender != address(poolOf[_projectId][_terminalToken])) revert JuiceBuyback_Unauthorized();

        bool _tokenProjectIs0 = _projectToken < _terminalToken;

        // delta is in regard of the pool balance (positive = pool need to receive)
        uint256 _amountToSendToPool = _tokenProjectIs0 ? uint256(amount1Delta) : uint256(amount0Delta);
        uint256 _amountReceivedForBeneficiary = _tokenProjectIs0 ? uint256(-amount0Delta) : uint256(-amount1Delta);

        // Revert if slippage is too high
        if (_amountReceivedForBeneficiary < _minimumAmountReceived) {
            revert JuiceBuyback_MaximumSlippage();
        }

        // Wrap ETH
        if (_terminalToken == JBTokens.ETH) WETH.deposit{value: _amountToSendToPool}();

        // Transfer the token to the pool
        IERC20(_terminalToken).transfer(msg.sender, _amountToSendToPool);
    }

    /**
     * @notice Generic redeem params, for interface completion
     *
     * @dev This is a passthrough of the redemption parameters
     *
     * @param _data the redeem data passed by the terminal
     */
    function redeemParams(JBRedeemParamsData calldata _data)
        external
        pure
        override
        returns (
            uint256 reclaimAmount,
            string memory memo,
            JBRedemptionDelegateAllocation3_1_1[] memory delegateAllocations
        )
    {
        return (_data.reclaimAmount.value, _data.memo, delegateAllocations);
    }

    /**
     * @notice Increase the period over which the twap is computed
     *
     * @param  _newSecondsAgo the new period
     */
    function changeSecondsAgo(uint256 _projectId, uint32 _newSecondsAgo) external onlyOwner {
        uint256 _oldValue = secondsAgoOf[_projectId];
        secondsAgoOf[_projectId] = _newSecondsAgo;

        emit BuybackDelegate_SecondsAgoChanged(_projectId, _oldValue, _newSecondsAgo);
    }

    /**
     * @notice Set the maximum deviation allowed between amount received and twap
     *
     * @param  _newDelta the new delta, in 10_000th
     */
    function setTwapDelta(uint256 _projectId, uint256 _newDelta) external onlyOwner {
        uint256 _oldDelta = twapDeltaOf[_projectId];
        twapDeltaOf[_projectId] = _newDelta;

        emit BuybackDelegate_TwapDeltaChanged(_projectId, _oldDelta, _newDelta);
    }

    /**
     * @notice Sweep the eth left-over in this contract
     */
    function sweep(IERC20 _token, address _beneficiary) external {
        // The beneficiary ETH balance in this contract leftover
        uint256 _balance = sweepBalanceOf[_beneficiary][_token];

        // If no balance, don't do anything
        if (_balance == 0) return;

        // Reset beneficiary balance
        sweepBalanceOf[_beneficiary][_token] = 0;
        unclaimedSweepBalanceOf[_token] -= _balance;

        if (_token == JBTokens.ETH) {
            // Send the eth to the beneficiary
            (bool _success,) = payable(_beneficiary).call{value: _balance}("");
            if (!_success) revert JuiceBuyback_TransferFailed();
        } else {
            _token.transfer(_beneficiary, _balance);
        }

        emit BuybackDelegate_PendingSweep(_beneficiary, _token, 0);
    }

    //*********************************************************************//
    // ---------------------- internal functions ------------------------- //
    //*********************************************************************//

    /**
     * @notice  Get a quote based on twap over a secondsAgo period, taking into account a twapDelta max deviation
     *
     * @param   _amountIn the amount to swap
     *
     * @return  _amountOut the minimum amount received according to the twap
     */
    function _getQuote(uint256 _projectId, IJBPaymentTerminal _terminal, IERC20 _projectToken, uint256 _amountIn)
        internal
        view
        returns (uint256 _amountOut)
    {
        IERC20 _terminalToken = IERC20(IJBSingleTokenPaymentTerminal(address(_terminal)).token());

        // Get the pool
        IUniswapV3Pool _pool = poolOf[_projectId][_terminalToken];

        // If non-existing or non-initialized pool, quote 0
        try _pool.slot0() returns (uint160, int24, uint16, uint16, uint16, uint8, bool unlocked) {
            // non initialized?
            if (!unlocked) return 0;
        } catch {
            // invalid address or not deployed yet?
            return 0;
        }

        // Get the twap tick
        (int24 arithmeticMeanTick,) = OracleLibrary.consult(address(_pool), secondsAgoOf[_projectId]);

        // Get a quote based on this twap tick
        _amountOut = OracleLibrary.getQuoteAtTick({
            tick: arithmeticMeanTick,
            baseAmount: uint128(_amountIn),
            baseToken: address(_terminalToken) == JBTokens.ETH ? address(WETH) : _terminalToken,
            quoteToken: address(_projectToken)
        });

        // Return the lowest twap accepted
        _amountOut -= (_amountOut * twapDeltaOf(_projectId)) / SLIPPAGE_DENOMINATOR;
    }

    /**
     * @notice Swap the terminal token to receive the project toke_beforeTransferTon
     *
     * @dev    This delegate first receive the whole amount of project token,
     *         then send the non-reserved token to the beneficiary,
     *         then burn the rest of this delegate balance (ie the amount of reserved token),
     *         then mint the same amount as received (this will add the reserved token, following the fc rate)
     *         then burn the difference (ie this delegate balance)
     *         -> End result is having the correct balances (beneficiary and reserve), according to the reserve rate
     *
     * @param  _data the didPayData passed by the terminal
     * @param  _minimumReceivedFromSwap the minimum amount received, to prevent slippage
     */
    function _swap(JBDidPayData3_1_1 calldata _data, uint256 _minimumReceivedFromSwap, IERC20 _projectToken)
        internal
        returns (uint256 _amountReceived)
    {

        bool _projectTokenIs0 = address(_projectToken) < _data.forwardedAmount.token;

        IUniswapV3Pool _pool = poolOf[_data.projectId][_data.forwardedAmount.token];

        // Pass the token and min amount to receive as extra data
        try _pool.swap({
            recipient: address(this),
            zeroForOne: !_projectTokenIs0,
            amountSpecified: int256(_data.forwardedAmount.value),
            sqrtPriceLimitX96: _projectTokenIs0 ? TickMath.MAX_SQRT_RATIO - 1 : TickMath.MIN_SQRT_RATIO + 1,
            data: abi.encode(_data.projectId, _minimumReceivedFromSwap, _data.forwardedAmount.token, _projectToken)
        }) returns (int256 amount0, int256 amount1) {
            // Swap succeded, take note of the amount of PROJECT_TOKEN received (negative as it is an exact input)
            _amountReceived = uint256(-(_projectTokenIs0 ? amount0 : amount1));
        } catch {
            // implies _amountReceived = 0 -> will later mint when back in didPay
            return _amountReceived;
        }

        CONTROLLER.burnTokensOf({
            holder: address(this),
            projectId: _data.projectId,
            tokenCount: _amountReceived,
            memo: "",
            preferClaimedTokens: true
        });

        CONTROLLER.mintTokensOf({
            projectId: _data.projectId,
            tokenCount: _amountReceived,
            beneficiary: address(_data.beneficiary),
            memo: _data.memo,
            preferClaimedTokens: _data.preferClaimedTokens,
            useReservedRate: true
        });

        emit BuybackDelegate_Swap(_data.projectId, _data.forwardedAmount.value, _amountReceived);
    }

    /**
     * @notice Mint the token out, sending back the token in the terminal
     *
     * @param  _data the didPayData passed by the terminal
     * @param  _amount the amount of token out to mint
     */
    function _mint(JBDidPayData3_1_1 calldata _data, uint256 _amount) internal {
        // Mint to the beneficiary with the fc reserve rate
        CONTROLLER.mintTokensOf({
            projectId: _data.projectId,
            tokenCount: _amount,
            beneficiary: _data.beneficiary,
            memo: _data.memo,
            preferClaimedTokens: _data.preferClaimedTokens,
            useReservedRate: true
        });

//TODO: ETH transfer vs erc20:
        // Send the eth back to the terminal balance
        IJBPayoutRedemptionPaymentTerminal3_1_1(msg.sender).addToBalanceOf{value: _data.forwardedAmount.value}(
            _data.projectId, _data.forwardedAmount.value, _data.forwardedAmount.token, "", ""
        );

        emit BuybackDelegate_Mint(_data.projectId);
    }

    //*********************************************************************//
    // ---------------------- peripheral functions ----------------------- //
    //*********************************************************************//

    function supportsInterface(bytes4 _interfaceId) public view override(ERC165, IERC165) returns (bool) {
        return _interfaceId == type(IJBFundingCycleDataSource3_1_1).interfaceId
            || _interfaceId == type(IJBPayDelegate3_1_1).interfaceId || super.supportsInterface(_interfaceId);
    }
}
