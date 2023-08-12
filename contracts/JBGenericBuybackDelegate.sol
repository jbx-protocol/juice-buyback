// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IJBPaymentTerminal} from "@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBPaymentTerminal.sol";
import {IJBPayoutRedemptionPaymentTerminal3_1_1 } from "@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBPayoutRedemptionPaymentTerminal3_1_1.sol";
import {IJBSingleTokenPaymentTerminal} from "@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBSingleTokenPaymentTerminal.sol";
import {JBDidPayData3_1_1} from "@jbx-protocol/juice-contracts-v3/contracts/structs/JBDidPayData3_1_1.sol";
import {IJBOperatable, JBOperatable} from "@jbx-protocol/juice-contracts-v3/contracts/abstract/JBOperatable.sol";
import {JBPayDelegateAllocation3_1_1} from "@jbx-protocol/juice-contracts-v3/contracts/structs/JBPayDelegateAllocation3_1_1.sol";
import {JBPayParamsData} from "@jbx-protocol/juice-contracts-v3/contracts/structs/JBPayParamsData.sol";
import {JBRedeemParamsData} from "@jbx-protocol/juice-contracts-v3/contracts/structs/JBRedeemParamsData.sol";
import {JBRedemptionDelegateAllocation3_1_1} from "@jbx-protocol/juice-contracts-v3/contracts/structs/JBRedemptionDelegateAllocation3_1_1.sol";
import {JBTokens} from "@jbx-protocol/juice-contracts-v3/contracts/libraries/JBTokens.sol";

import {JBDelegateMetadataLib} from "@jbx-protocol/juice-delegate-metadata-lib/src/JBDelegateMetadataLib.sol";

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {ERC165, IERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

import {mulDiv18} from "@prb/math/src/Common.sol";

import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {OracleLibrary} from "@uniswap/v3-periphery/contracts/libraries/OracleLibrary.sol";

import {JBBuybackDelegateOperations} from "./libraries/JBBuybackDelegateOperations.sol";
import /** {*} from */ "./interfaces/IJBGenericBuybackDelegate.sol";

/**
 * @custom:benediction DEVS BENEDICAT ET PROTEGAT CONTRACTVS MEAM
 *
 * @title  Generic Buyback Delegate compatible with any jb terminal, any project token (except fee on transfer)
 *
 * @notice Datasource and delegate allowing pay beneficiary to get the highest amount
 *         of project tokens between minting using the project weigh and swapping in a
 *         given Uniswap V3 pool
 *
 * @dev    This supports any terminal and token, as well as any number of projects using it.
 */

contract JBGenericBuybackDelegate is
    ERC165,
    JBOperatable,
    IJBGenericBuybackDelegate
{

    //*********************************************************************//
    // --------------------- public constant properties ----------------- //
    //*********************************************************************//
    /**
     * @notice The unit of the max slippage (expressed in 1/10000th)
     */
    uint256 public constant SLIPPAGE_DENOMINATOR = 10000;

    /**
     * @notice The minimum twap deviation allowed (0.1%, in 1/10000th)
     *
     * @dev    This is to avoid bypassing the swap when a quote is not provided
     *         (ie in fees/automated pay)
     */
    uint256 public constant MIN_TWAP_DELTA = 100;

    /**
     * @notice The minimmaximum twap deviation allowed (9%, in 1/10000th)
     *
     * @dev    This is to avoid bypassing the swap when a quote is not provided
     *         (ie in fees/automated pay)
     */
    uint256 public constant MAX_TWAP_DELTA = 9000;

    /**
     * @notice The smallest TWAP period allowed, in seconds.
     *
     * @dev    This is to avoid having a too short twap, prone to pool manipulation
     */ 
    uint256 public constant MIN_SECONDS_AGO = 2 minutes;

    /**
     * @notice The biggest TWAP period allowed, in seconds.
     *
     * @dev    This is to avoid having a too long twap, bypassing the swap
     */
    uint256 public constant MAX_SECONDS_AGO = 2 days;

    /**
     * @notice The uniswap v3 factory
     */
    address public immutable UNISWAP_V3_FACTORY;

    /**
     * @notice The JB Directory
     */
    IJBDirectory public immutable DIRECTORY;

    /**
     * @notice The project controller
     */
    IJBController3_1 public immutable CONTROLLER;

    /**
     * @notice The project registry
     */
    IJBProjects public immutable PROJECTS;

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
    mapping(uint256 _projectId => mapping(address _terminalToken => IUniswapV3Pool _pool)) public poolOf;

    /**
     * @notice The project token
     */
    mapping(uint256 _projectId => address projectTokenOf) public projectTokenOf;

    /**
     * @notice Any ETH left-over in this contract (from swap in the end of liquidity range)
     */
    mapping(address _beneficiary => mapping(address _token => uint256 _balance)) public sweepBalanceOf;

    /**
     * @notice Running cumulative sum of token left-over
     */
    mapping(address _token => uint256 _contractBalance) public totalSweepBalance;

    /////////////////////////////////////////////////////////////////////
    //                    Internal global variables                    //
    /////////////////////////////////////////////////////////////////////

    /**
     * @notice The twap max deviation acepted (in 10_000th) and timeframe to use for the pool twap (from secondAgo to now)
     *
     * @dev    Params are uint128 and uint32 packed in a uint256, with the max deviation in the 128 most significant bits
     */
    mapping(uint256 _projectId => uint256 _params) internal twapParamsOf;

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
    ) JBOperatable(IJBOperatable(address(_controller)).operatorStore()) {
        WETH = _weth;
        DIRECTORY = _directory;
        CONTROLLER = _controller;
        UNISWAP_V3_FACTORY = _factory;
        delegateId = _delegateId;

        PROJECTS = _controller.projects();
    }

    /////////////////////////////////////////////////////////////////////
    //                         View functions                          //
    /////////////////////////////////////////////////////////////////////

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
        address _projectToken = projectTokenOf[_data.projectId];

        // Find the total number of tokens to mint, as a fixed point number with 18 decimals
        uint256 _tokenCount = mulDiv18(_data.amount.value, _data.weight);

        // Unpack the quote from the pool, given by the frontend - this one takes precedence on the twap
        // as it should be closer to the current pool state, if not, use the twap
        (bool _validQuote, bytes memory _metadata) = JBDelegateMetadataLib.getMetadata(delegateId, _data.metadata);

        // Get a quote based on either the frontend quote or a twap from the pool
        uint256 _quote;
        uint256 _slippage;
        if (_validQuote) (_quote, _slippage) = abi.decode(_metadata, (uint256, uint256));

        uint256 _swapAmountOut = _quote == 0
         ? _getQuote(_data.projectId, _data.terminal, _projectToken, _data.amount.value)
         : _quote - ((_quote * _slippage) / SLIPPAGE_DENOMINATOR);

        // If the minimum amount received from swapping is greather than received when minting, use the swap pathway
        if (_tokenCount < _swapAmountOut) {
            // Return this delegate as the one to use, along the quote and reserved rate, and do not mint from the terminal
            delegateAllocations = new JBPayDelegateAllocation3_1_1[](1);
            delegateAllocations[0] = JBPayDelegateAllocation3_1_1({
                delegate: IJBPayDelegate3_1_1(this),
                amount: _data.amount.value,
                metadata: abi.encode(_tokenCount, _swapAmountOut, _projectToken)
            });

            return (0, _data.memo, delegateAllocations);
        }

        // If minting, do not use this as delegate (delegateAllocations is left uninitialised)
        return (_data.weight, _data.memo, delegateAllocations);
    }

    /**
     * @notice The timeframe to use for the pool twap (from secondAgo to now)
     *
     * @param  _projectId the project id
     *
     * @return _secondsAgo the period over which the twap is computed
     */
    function secondsAgoOf(uint256 _projectId) external view returns(uint32) {
        return uint32(twapParamsOf[_projectId]);
    }

    /**
     * @notice The twap max deviation acepted (in 10_000th)
     *
     * @param  _projectId the project id
     *
     * @return _delta the maximum deviation allowed between amount received and twap
     */
    function twapDeltaOf(uint256 _projectId) external view returns(uint256) {
        return twapParamsOf[_projectId] >> 128;
    }

    /////////////////////////////////////////////////////////////////////
    //                       External functions                        //
    /////////////////////////////////////////////////////////////////////

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

        // Any leftover in this contract?
        uint256 _terminalTokenInThisContract = _data.forwardedAmount.token == JBTokens.ETH
            ? address(this).balance
            : IERC20(_data.forwardedAmount.token).balanceOf(address(this));

        // Any previous leftover?
        uint256 _terminalTokenPreviouslyInThisContract = totalSweepBalance[_data.forwardedAmount.token];

        // From these previous leftover, some belonging to the beneficiary?
        uint256 _beneficiarySweepBalance = sweepBalanceOf[_data.beneficiary][_data.forwardedAmount.token];

        // Add any new leftover to the beneficiary and contract balance
        if (_terminalTokenInThisContract > 0 && _terminalTokenInThisContract != _beneficiarySweepBalance) {
            sweepBalanceOf[_data.beneficiary][_data.forwardedAmount.token] +=
                _terminalTokenInThisContract - _terminalTokenPreviouslyInThisContract;

            emit BuybackDelegate_PendingSweep(
                _data.beneficiary,
                _data.forwardedAmount.token,
                _terminalTokenInThisContract - _terminalTokenPreviouslyInThisContract
            );

            totalSweepBalance[_data.forwardedAmount.token] = _terminalTokenInThisContract;
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

        // Get the terminal token, weth if it's an ETH terminal
        address _terminalTokenWithWETH = _terminalToken == JBTokens.ETH ? address(WETH) : _terminalToken;

        // Check if this is really a callback - only create2 pools are added to insure safety of this check (balance pending sweep at risk)
        if (msg.sender != address(poolOf[_projectId][_terminalTokenWithWETH])) revert JuiceBuyback_Unauthorized();

        // Sort the pool tokens
        bool _tokenProjectIs0 = _projectToken < _terminalTokenWithWETH;

        // delta is in regard of the pool balance (positive = pool need to receive)
        uint256 _amountToSendToPool = _tokenProjectIs0 ? uint256(amount1Delta) : uint256(amount0Delta);
        uint256 _amountReceivedForBeneficiary = _tokenProjectIs0 ? uint256(-amount0Delta) : uint256(-amount1Delta);

        // Revert if slippage is too high
        if (_amountReceivedForBeneficiary < _minimumAmountReceived) {
            revert JuiceBuyback_MaximumSlippage();
        }

        // Wrap ETH if needed
        if (_terminalToken == JBTokens.ETH) WETH.deposit{value: _amountToSendToPool}();

        // Transfer the token to the pool
        IERC20(_terminalTokenWithWETH).transfer(msg.sender, _amountToSendToPool);
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
     * @notice Add a pool for a given project. This pools the become the default one for a given token project-terminal token
     *
     * @dev    Uses create2 for callback auth and allows adding a pool not deployed yet.
     *         This can be called by the project owner or an address having the SET_POOL permission in JBOperatorStore
     *
     * @param  _projectId the project id
     * @param  _fee the fee of the pool
     * @param  _secondsAgo the period over which the twap is computed
     * @param  _twapDelta the maximum deviation allowed between amount received and twap
     * @param  _terminalToken the terminal token
     */
    function setPoolFor(uint256 _projectId, uint24 _fee, uint32 _secondsAgo, uint256 _twapDelta, address _terminalToken)
        external
        requirePermission(PROJECTS.ownerOf(_projectId), _projectId, JBBuybackDelegateOperations.CHANGE_POOL)
        returns (IUniswapV3Pool _newPool)
    {
        if (_twapDelta < MIN_TWAP_DELTA || _twapDelta > MAX_TWAP_DELTA) revert JuiceBuyback_InvalidTwapDelta();

        if ( _secondsAgo < MIN_SECONDS_AGO || _secondsAgo > MAX_SECONDS_AGO) revert JuiceBuyback_InvalidTwapPeriod();

        // Get the project token
        address _projectToken = address(CONTROLLER.tokenStore().tokenOf(_projectId));

        if (_projectToken == address(0)) revert JuiceBuyback_NoProjectToken();

        if (_terminalToken == JBTokens.ETH) _terminalToken = address(WETH);

        bool _projectTokenIs0 = address(_projectToken) < _terminalToken;

        // Compute the corresponding pool
        _newPool = IUniswapV3Pool(
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

        // If this pool is already used, rather use the secondsAgo and twapDelta setters
        if (poolOf[_projectId][_terminalToken] == _newPool) revert JuiceBuyback_PoolAlreadySet();

        // Store the pool
        poolOf[_projectId][_terminalToken] = _newPool;

        // Store the twap period and max slippage
        twapParamsOf[_projectId] = _twapDelta << 128 | _secondsAgo;
        projectTokenOf[_projectId] = address(_projectToken);

        emit BuybackDelegate_SecondsAgoChanged(_projectId, 0, _secondsAgo);
        emit BuybackDelegate_TwapDeltaChanged(_projectId, 0, _twapDelta);
        emit BuybackDelegate_PoolAdded(_projectId, _terminalToken, address(_newPool));
    }

    /**
     * @notice Increase the period over which the twap is computed
     *
     * @dev    This can be called by the project owner or an address having the SET_TWAP_PERIOD permission in JBOperatorStore
     *
     * @param  _newSecondsAgo the new period
     */
    function changeSecondsAgo(uint256 _projectId, uint32 _newSecondsAgo)
        external
        requirePermission(PROJECTS.ownerOf(_projectId), _projectId, JBBuybackDelegateOperations.SET_POOL_PARAMS)
    {
        if (_newSecondsAgo < MIN_SECONDS_AGO || _newSecondsAgo > MAX_SECONDS_AGO) revert JuiceBuyback_InvalidTwapPeriod();

        uint256 _twapParams = twapParamsOf[_projectId];
        uint256 _oldValue = uint128(_twapParams);

        twapParamsOf[_projectId] = uint256(_newSecondsAgo) | ((_twapParams >> 128) << 128);

        emit BuybackDelegate_SecondsAgoChanged(_projectId, _oldValue, _newSecondsAgo);
    }

    /**
     * @notice Set the maximum deviation allowed between amount received and twap
     *
     * @dev    This can be called by the project owner or an address having the SET_POOL permission in JBOperatorStore
     *
     * @param  _newDelta the new delta, in 10_000th
     */
    function setTwapDelta(uint256 _projectId, uint256 _newDelta)
        external
        requirePermission(PROJECTS.ownerOf(_projectId), _projectId, JBBuybackDelegateOperations.SET_POOL_PARAMS)
    {
        if (_newDelta < MIN_TWAP_DELTA || _newDelta > MAX_TWAP_DELTA) revert JuiceBuyback_InvalidTwapDelta();

        uint256 _twapParams = twapParamsOf[_projectId];
        uint256 _oldDelta = _twapParams >> 128;

        twapParamsOf[_projectId] = _newDelta << 128 | ((_twapParams << 128) >> 128);

        emit BuybackDelegate_TwapDeltaChanged(_projectId, _oldDelta, _newDelta);
    }

    /**
     * @notice Sweep the token left-over in this contract
     */
    function sweep(address _beneficiary, address _token) external {
        // The beneficiary ETH balance in this contract leftover
        uint256 _balance = sweepBalanceOf[_beneficiary][_token];

        // If no balance, don't do anything
        if (_balance == 0) return;

        // Reset beneficiary balance
        sweepBalanceOf[_beneficiary][_token] = 0;
        totalSweepBalance[_token] -= _balance;

        if (_token == JBTokens.ETH) {
            // Send the eth to the beneficiary
            (bool _success,) = payable(_beneficiary).call{value: _balance}("");
            if (!_success) revert JuiceBuyback_TransferFailed();
        } else {
            IERC20(_token).transfer(_beneficiary, _balance);
        }

        emit BuybackDelegate_PendingSweep(_beneficiary, address(_token), 0);
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
    function _getQuote(uint256 _projectId, IJBPaymentTerminal _terminal, address _projectToken, uint256 _amountIn)
        internal
        view
        returns (uint256 _amountOut)
    {
        address _terminalToken = IJBSingleTokenPaymentTerminal(address(_terminal)).token();

        // Get the pool
        IUniswapV3Pool _pool = poolOf[_projectId][address(_terminalToken)];

        // If non-existing or non-initialized pool, quote 0
        try _pool.slot0() returns (uint160, int24, uint16, uint16, uint16, uint8, bool unlocked) {
            // non initialized?
            if (!unlocked) return 0;
        } catch {
            // invalid address or not deployed yet?
            return 0;
        }

        // Get and unpack the twap params
        uint256 _twapParams = twapParamsOf[_projectId];
        uint32 _quotePeriod = uint32(_twapParams);
        uint256 _maxDelta = _twapParams >> 128;

        // Get the twap tick
        (int24 arithmeticMeanTick,) = OracleLibrary.consult(address(_pool), _quotePeriod);

        // Get a quote based on this twap tick
        _amountOut = OracleLibrary.getQuoteAtTick({
            tick: arithmeticMeanTick,
            baseAmount: uint128(_amountIn),
            baseToken: _terminalToken == JBTokens.ETH ? address(WETH) : _terminalToken,
            quoteToken: address(_projectToken)
        });

        // Return the lowest twap accepted
        _amountOut -= (_amountOut * _maxDelta) / SLIPPAGE_DENOMINATOR;
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
        address _terminalToken =
            _data.forwardedAmount.token == JBTokens.ETH ? address(WETH) : _data.forwardedAmount.token;

        bool _projectTokenIs0 = address(_projectToken) < _terminalToken;

        IUniswapV3Pool _pool = poolOf[_data.projectId][_terminalToken];

        // Pass the token and min amount to receive as extra data
        try _pool.swap({
            recipient: address(this),
            zeroForOne: !_projectTokenIs0,
            amountSpecified: int256(_data.forwardedAmount.value),
            sqrtPriceLimitX96: _projectTokenIs0 ? TickMath.MAX_SQRT_RATIO - 1 : TickMath.MIN_SQRT_RATIO + 1,
            data: abi.encode(_data.projectId, _minimumReceivedFromSwap, _terminalToken, _projectToken)
        }) returns (int256 amount0, int256 amount1) {
            // Swap succeded, take note of the amount of PROJECT_TOKEN received (negative as it is an exact input)
            _amountReceived = uint256(-(_projectTokenIs0 ? amount0 : amount1));
        } catch {
            // implies _amountReceived = 0 -> will later mint when back in didPay
            return _amountReceived;
        }

        // Burn the whole amount received
        CONTROLLER.burnTokensOf({
            holder: address(this),
            projectId: _data.projectId,
            tokenCount: _amountReceived,
            memo: "",
            preferClaimedTokens: true
        });

        // Mint it again, to add the correct portion to the reserved token and take the claimed preference into account
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

        // Add the token or eth back to the terminal balance
        if (_data.forwardedAmount.token != JBTokens.ETH) {
            IERC20(_data.forwardedAmount.token).approve(msg.sender, _data.forwardedAmount.value);
        }

        IJBPayoutRedemptionPaymentTerminal3_1_1(msg.sender).addToBalanceOf{
            value: _data.forwardedAmount.token == JBTokens.ETH ? _data.forwardedAmount.value : 0
        }(_data.projectId, _data.forwardedAmount.value, _data.forwardedAmount.token, "", "");

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
