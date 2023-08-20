// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IJBPaymentTerminal} from "@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBPaymentTerminal.sol";
import {IJBPayoutRedemptionPaymentTerminal3_1_1} from
    "@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBPayoutRedemptionPaymentTerminal3_1_1.sol";
import {IJBSingleTokenPaymentTerminal} from
    "@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBSingleTokenPaymentTerminal.sol";
import {JBDidPayData3_1_1} from "@jbx-protocol/juice-contracts-v3/contracts/structs/JBDidPayData3_1_1.sol";
import {IJBOperatable, JBOperatable} from "@jbx-protocol/juice-contracts-v3/contracts/abstract/JBOperatable.sol";
import {JBPayDelegateAllocation3_1_1} from
    "@jbx-protocol/juice-contracts-v3/contracts/structs/JBPayDelegateAllocation3_1_1.sol";
import {JBPayParamsData} from "@jbx-protocol/juice-contracts-v3/contracts/structs/JBPayParamsData.sol";
import {JBRedeemParamsData} from "@jbx-protocol/juice-contracts-v3/contracts/structs/JBRedeemParamsData.sol";
import {JBRedemptionDelegateAllocation3_1_1} from
    "@jbx-protocol/juice-contracts-v3/contracts/structs/JBRedemptionDelegateAllocation3_1_1.sol";
import {JBTokens} from "@jbx-protocol/juice-contracts-v3/contracts/libraries/JBTokens.sol";

import {JBDelegateMetadataLib} from "@jbx-protocol/juice-delegate-metadata-lib/src/JBDelegateMetadataLib.sol";

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {ERC165, IERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

import {mulDiv18, mulDiv} from "@prb/math/src/Common.sol";

import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {OracleLibrary} from "@uniswap/v3-periphery/contracts/libraries/OracleLibrary.sol";

import {JBBuybackDelegateOperations} from "./libraries/JBBuybackDelegateOperations.sol";
import
/**
     * {*} from
     */
    "./interfaces/IJBGenericBuybackDelegate.sol";

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

contract JBGenericBuybackDelegate is ERC165, JBOperatable, IJBGenericBuybackDelegate {
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
        // Keep a reference to the minimum number of tokens expected to be swapped for.
        uint256 _minimumSwapAmountOut;

        // Keep a reference to the amount from the payment to allocate towards a swap.
        uint256 _amountToSwapWith;

        // Keep a reference to a flag indicating if the quote passed into the metadata is valid.
        bool _validQuote;

        // Scoped section to prevent Stack Too Deep.
        {
            bytes memory _metadata;

            // Unpack the quote from the pool, given by the frontend.
            (_validQuote, _metadata) = JBDelegateMetadataLib.getMetadata(delegateId, _data.metadata);
            if (_validQuote) (_minimumSwapAmountOut, _amountToSwapWith) = abi.decode(_metadata, (uint256, uint256));

            // If no amount was specified to swap with, default to the full amount of the payment.
            if (_amountToSwapWith == 0) _amountToSwapWith = _data.amount.value;
        }

        // Find the default total number of tokens to mint as if no Buyback Delegate were installed, as a fixed point number with 18 decimals
        uint256 _tokenCount = mulDiv18(_amountToSwapWith, _data.weight);

        // Keep a reference to the project's token.
        address _projectToken = projectTokenOf[_data.projectId];

        // Keep a reference to the token being used by the terminal that is calling this delegate.
        address _terminalToken = _data.amount.token == JBTokens.ETH ? address(WETH) : _data.amount.token;

        // If a minimum amount of tokens to swap for wasn't specified, resolve a value as good as possible using a TWAP.
        if (_minimumSwapAmountOut == 0) {
            _minimumSwapAmountOut = _getQuote(_data.projectId, _data.terminal, _projectToken, _amountToSwapWith, _terminalToken);
        }

        // If the minimum amount received from swapping is greather than received when minting, use the swap path.
        if (_tokenCount < _minimumSwapAmountOut) {
            // Make sure the amount to swap with is at most the full amount being paid.
            if (_amountToSwapWith > _data.amount.value) {
                revert JuiceBuyback_InsufficientPayAmount();
            }

            // Keep a reference to a flag indicating if the pool will reference the project token as the first in the pair.
            bool _projectTokenIs0 = address(_projectToken) < _terminalToken;

            // Return this delegate as the one to use, while forwarding the amount to swap with. Speficy metadata that allows the swap to be executed.
            delegateAllocations = new JBPayDelegateAllocation3_1_1[](1);
            delegateAllocations[0] = JBPayDelegateAllocation3_1_1({
                delegate: IJBPayDelegate3_1_1(this),
                amount: _amountToSwapWith,
                metadata: abi.encode(_validQuote, _minimumSwapAmountOut, _data.weight, _terminalToken, _projectTokenIs0)
            });

            // Mint the amount not specified for swaping.
            return (
                mulDiv(_data.amount.value - _amountToSwapWith, _data.weight, _data.amount.value),
                _data.memo,
                delegateAllocations
            );
        }

        // If minting, delegateAllocations is left uninitialised.
        return (_data.weight, _data.memo, delegateAllocations);
    }

    /**
     * @notice The timeframe to use for the pool twap (from secondAgo to now)
     *
     * @param  _projectId the project id
     *
     * @return _secondsAgo the period over which the twap is computed
     */
    function secondsAgoOf(uint256 _projectId) external view returns (uint32) {
        return uint32(twapParamsOf[_projectId]);
    }

    /**
     * @notice The twap max deviation acepted (in 10_000th)
     *
     * @param  _projectId the project id
     *
     * @return _delta the maximum deviation allowed between amount received and twap
     */
    function twapDeltaOf(uint256 _projectId) external view returns (uint256) {
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
        // Make sure only a payment terminal belonging to the project can access this functionality.
        if (!DIRECTORY.isTerminalOf(_data.projectId, IJBPaymentTerminal(msg.sender))) {
            revert JuiceBuyback_Unauthorized();
        }

        // Parse the metadata passed in from the data source.
        (
            bool _validQuote,
            uint256 _minimumSwapAmountOut,
            uint256 _weight,
            address _terminalToken,
            bool _projectTokenIs0
        ) = abi.decode(_data.dataSourceMetadata, (bool, uint256, uint256, address, bool));

        // Get a reference to the amount of tokens that was swapped for.
        uint256 _exactSwapAmountOut =
            _swap(_data, _minimumSwapAmountOut, _data.forwardedAmount.value, _terminalToken, _projectTokenIs0);

        // If no tokens were swapped for, mint instead if the quote was determined from a TWAP. Otherwise revert so that the caller can refine their provided quote.
        if (_exactSwapAmountOut == 0) {
            // if a valid quote, suggests TWAP wasn't used.
            if (_validQuote) {
                revert JuiceBuyback_MaximumSlippage();
            } else {
                _mint(_data, _data.forwardedAmount.value, _weight);
            }
        } else {
            // If the swap was successfull, get a reference to any amount of tokens paid in remaining in this contract.
            uint256 _terminalTokenInThisContract = _data.forwardedAmount.token == JBTokens.ETH
                ? address(this).balance
                : IERC20(_data.forwardedAmount.token).balanceOf(address(this));

            // Use any leftover amount of tokens paid in remaining to mint.
            if (_terminalTokenInThisContract != 0) {
                _mint(_data, _terminalTokenInThisContract, _weight);
            }
        }
    }

    /**
     * @notice The Uniswap V3 pool callback (where token transfer should happens)
     *
     * @dev    Slippage controle is achieved here
     */
    function uniswapV3SwapCallback(int256 _amount0Delta, int256 _amount1Delta, bytes calldata _data)
        external
        override
    {
        // Unpack the data passed in through the swap hook.
        (uint256 _projectId, address _terminalToken, bool _tokenProjectIs0) =
            abi.decode(_data, (uint256, address, bool));

        // Get the terminal token, using WETH if the token paid in is ETH.
        address _terminalTokenWithWETH = _terminalToken == JBTokens.ETH ? address(WETH) : _terminalToken;

        // Make sure this call is being made from within the swap execution. 
        if (msg.sender != address(poolOf[_projectId][_terminalTokenWithWETH])) revert JuiceBuyback_Unauthorized();

        // Keep a reference to the amount of tokens that should be sent to fulfill the swap.
        uint256 _amountToSendToPool = _tokenProjectIs0 ? uint256(_amount1Delta) : uint256(_amount0Delta);

        // Wrap ETH into WETH if relevant. 
        if (_terminalToken == JBTokens.ETH) WETH.deposit{value: _amountToSendToPool}();

        // Transfer the token to the pool.
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
        // Make sure the provided delta is within sane bounds.
        if (_twapDelta < MIN_TWAP_DELTA || _twapDelta > MAX_TWAP_DELTA) revert JuiceBuyback_InvalidTwapDelta();

        // Make sure the provided period is within sane bounds.
        if (_secondsAgo < MIN_SECONDS_AGO || _secondsAgo > MAX_SECONDS_AGO) revert JuiceBuyback_InvalidTwapPeriod();

        // Keep a reference to the project's token.
        address _projectToken = address(CONTROLLER.tokenStore().tokenOf(_projectId));

        // Make sure the project has issued a token.
        if (_projectToken == address(0)) revert JuiceBuyback_NoProjectToken();
        
        // If the terminal token specified in ETH, use WETH instead.
        if (_terminalToken == JBTokens.ETH) _terminalToken = address(WETH);

        // Keep a reference to a flag indicating if the pool will reference the project token as the first in the pair.
        bool _projectTokenIs0 = address(_projectToken) < _terminalToken;

        // Compute the corresponding pool's address, which is a function of both tokens and the specified fee.
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

        // Make sure this pool has yet to be specified in this delegate.
        if (poolOf[_projectId][_terminalToken] == _newPool) revert JuiceBuyback_PoolAlreadySet();

        // Store the pool.
        poolOf[_projectId][_terminalToken] = _newPool;

        // Store the twap period and max slipage.
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
        // Make sure the provided period is within sane bounds.
        if (_newSecondsAgo < MIN_SECONDS_AGO || _newSecondsAgo > MAX_SECONDS_AGO) {
            revert JuiceBuyback_InvalidTwapPeriod();
        }

        // Keep a reference to the currently stored TWAP params.
        uint256 _twapParams = twapParamsOf[_projectId];

        // Keep a reference to the old period value.
        uint256 _oldValue = uint128(_twapParams);

        // Store the new packed value of the TWAP params.
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
        // Make sure the provided delta is within sane bounds.
        if (_newDelta < MIN_TWAP_DELTA || _newDelta > MAX_TWAP_DELTA) revert JuiceBuyback_InvalidTwapDelta();

        // Keep a reference to the currently stored TWAP params.
        uint256 _twapParams = twapParamsOf[_projectId];
        
        // Keep a reference to the old slippage value.
        uint256 _oldDelta = _twapParams >> 128;

        // Store the new packed value of the TWAP params.
        twapParamsOf[_projectId] = _newDelta << 128 | ((_twapParams << 128) >> 128);

        emit BuybackDelegate_TwapDeltaChanged(_projectId, _oldDelta, _newDelta);
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
    function _getQuote(uint256 _projectId, IJBPaymentTerminal _terminal, address _projectToken, uint256 _amountIn, address _terminalToken)
        internal
        view
        returns (uint256 _amountOut)
    {
        // Get a reference to the pool that'll be used to make the swap.
        IUniswapV3Pool _pool = poolOf[_projectId][address(_terminalToken)];

        // Make sure the pool exists.
        try _pool.slot0() returns (uint160, int24, uint16, uint16, uint16, uint8, bool unlocked) {
            // If the pool hasn't been initialized, return an empty quote.
            if (!unlocked) return 0;
        } catch {
            // If the address is invalid or if the pool has not yet been deployed, return an empty quote.
            return 0;
        }

        // Unpack the TWAP params and get a reference to the period and slippage.
        uint256 _twapParams = twapParamsOf[_projectId];
        uint32 _quotePeriod = uint32(_twapParams);
        uint256 _maxDelta = _twapParams >> 128;

        // Keep a reference to the TWAP tick.
        (int24 arithmeticMeanTick,) = OracleLibrary.consult(address(_pool), _quotePeriod);

        // Get a quote based on this TWAP tick.
        _amountOut = OracleLibrary.getQuoteAtTick({
            tick: arithmeticMeanTick,
            baseAmount: uint128(_amountIn),
            baseToken: _terminalToken == JBTokens.ETH ? address(WETH) : _terminalToken,
            quoteToken: address(_projectToken)
        });

        // Return the lowest TWAP tolerable.
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
     * @param  _minimumSwapAmountOut the amount received, to prevent slippage
     */
    function _swap(
        JBDidPayData3_1_1 calldata _data,
        uint256 _minimumSwapAmountOut,
        uint256 _amountToSwapWith,
        address _terminalToken,
        bool _projectTokenIs0
    ) internal returns (uint256 _amountReceived) {
        
        // Get a reference to the pool that'll be used to make the swap.
        IUniswapV3Pool _pool = poolOf[_data.projectId][_terminalToken];

        // Try swapping.
        try _pool.swap({
            recipient: address(this),
            zeroForOne: !_projectTokenIs0,
            amountSpecified: int256(_amountToSwapWith),
            sqrtPriceLimitX96: _projectTokenIs0 ? TickMath.MAX_SQRT_RATIO - 1 : TickMath.MIN_SQRT_RATIO + 1,
            data: abi.encode(_data.projectId, _terminalToken, _projectTokenIs0)
        }) returns (int256 amount0, int256 amount1) {
            // If the swap succeded, take note of the amount of tokens received. This will return as negative since it is an exact input.
            _amountReceived = uint256(-(_projectTokenIs0 ? amount0 : amount1));
        } catch {
            // If the swap failed, return.
            return 0;
        }

        // Make sure the slippage is tolerable.
        if (_amountReceived < _minimumSwapAmountOut) {
            revert JuiceBuyback_MaximumSlippage();
        }

        // Burn the whole amount received.
        CONTROLLER.burnTokensOf({
            holder: address(this),
            projectId: _data.projectId,
            tokenCount: _amountReceived,
            memo: "",
            preferClaimedTokens: true
        });

        // Mint the whole amount of tokens again, such that the correct portion of reserved tokens get taken into account.
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
    function _mint(JBDidPayData3_1_1 calldata _data, uint256 _amount, uint256 _weight)
        internal
        returns (uint256 _tokenCount)
    {
        // Keep a reference to the amount of tokens that should be minted.
        _tokenCount = mulDiv18(_amount, _weight);

        // Mint to the beneficiary, making sure the reserved rate gets taken into account.
        CONTROLLER.mintTokensOf({
            projectId: _data.projectId,
            tokenCount: _tokenCount,
            beneficiary: _data.beneficiary,
            memo: _data.memo,
            preferClaimedTokens: _data.preferClaimedTokens,
            useReservedRate: true
        });

        // If the token paid in wasn't ETH, give the terminal permission to pull them back into its balance.
        if (_data.forwardedAmount.token != JBTokens.ETH) {
            IERC20(_data.forwardedAmount.token).approve(msg.sender, _data.forwardedAmount.value);
        }

        // Add the paid amount back to the project's terminal balance.
        IJBPayoutRedemptionPaymentTerminal3_1_1(msg.sender).addToBalanceOf{
            value: _data.forwardedAmount.token == JBTokens.ETH ? _amount : 0
        }(_data.projectId, _amount, _data.forwardedAmount.token, "", "");

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
