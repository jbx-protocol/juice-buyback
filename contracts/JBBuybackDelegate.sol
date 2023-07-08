// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import {IJBController3_1} from "@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBController3_1.sol";
import {IJBFundingCycleDataSource} from
    "@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBFundingCycleDataSource.sol";
import {IJBPayDelegate} from "@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBPayDelegate.sol";
import {IJBPayoutRedemptionPaymentTerminal3_1} from
    "@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBPayoutRedemptionPaymentTerminal3_1.sol";

import {JBConstants} from "@jbx-protocol/juice-contracts-v3/contracts/libraries/JBConstants.sol";
import {JBFundingCycle} from "@jbx-protocol/juice-contracts-v3/contracts/structs/JBFundingCycle.sol";
import {JBTokens} from "@jbx-protocol/juice-contracts-v3/contracts/libraries/JBTokens.sol";

import {JBDidPayData} from "@jbx-protocol/juice-contracts-v3/contracts/structs/JBDidPayData.sol";
import {JBPayParamsData} from "@jbx-protocol/juice-contracts-v3/contracts/structs/JBPayParamsData.sol";
import {JBRedeemParamsData} from "@jbx-protocol/juice-contracts-v3/contracts/structs/JBRedeemParamsData.sol";
import {JBPayDelegateAllocation} from "@jbx-protocol/juice-contracts-v3/contracts/structs/JBPayDelegateAllocation.sol";
import {JBRedemptionDelegateAllocation} from
    "@jbx-protocol/juice-contracts-v3/contracts/structs/JBRedemptionDelegateAllocation.sol";

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {ERC165, IERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {mulDiv, mulDiv18} from "@prb/math/src/common.sol";

import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3SwapCallback} from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";

import {OracleLibrary} from "@uniswap/v3-periphery/contracts/libraries/OracleLibrary.sol";

import {IWETH9} from "./interfaces/external/IWETH9.sol";

/**
 * @custom:benediction DEVS BENEDICAT ET PROTEGAT CONTRACTVS MEAM
 *
 * @title  Buyback Delegate
 *
 * @notice Datasource and delegate allowing pay beneficiary to get the highest amount
 *         of project tokens between minting using the project weigh and swapping in a
 *         given Uniswap V3 pool
 *
 * @dev    This only supports ETH terminal. The pool is fixed, if a new pool offers deeper
 *         liquidity, this delegate needs to be redeployed.
*/
contract JBBuybackDelegate is Ownable, ERC165, IJBFundingCycleDataSource, IJBPayDelegate, IUniswapV3SwapCallback {
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

    event BuybackDelegate_Swap(uint256 projectId, uint256 amountEth, uint256 amountOut);
    event BuybackDelegate_Mint(uint256 projectId);
    event BuybackDelegate_SecondsAgoIncrease(uint256 oldSecondsAgo, uint256 newSecondsAgo);
    event BuybackDelegate_TwapDeltaChanged(uint256 oldTwapDelta, uint256 newTwapDelta);
    event BuybackDelegate_PendingSweep(address indexed beneficiary, uint256 amount);

    //*********************************************************************//
    // --------------------- private constant properties ----------------- //
    //*********************************************************************//

    /**
     * @notice Address project token < address terminal token ?
     */
    bool immutable PROJECT_TOKEN_IS_TOKEN0;

    /**
     * @notice The unit of the max slippage (expressed in 1/10000th)
     */
    uint256 constant SLIPPAGE_DENOMINATOR = 10000;

    //*********************************************************************//
    // --------------------- public constant properties ------------------ //
    //*********************************************************************//

    /**
     * @notice The project token address
     *
     * @dev In this context, this is the tokenOut
     */
    IERC20 public immutable PROJECT_TOKEN;

    /**
     * @notice The uniswap pool corresponding to the project token-other token market
     *         (this should be carefully chosen liquidity wise)
     */
    IUniswapV3Pool public immutable POOL;

    /**
     * @notice The project terminal using this extension
     */
    IJBPayoutRedemptionPaymentTerminal3_1 public immutable TERMINAL;

    /**
     * @notice The terminal store associated with the terminal
     */
    address public immutable TERMINAL_STORE;

    /**
     * @notice The project controller
     */
    IJBController3_1 public immutable CONTROLLER;

    /**
     * @notice The WETH contract
     */
    IWETH9 public immutable WETH;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    // the timeframe to use for the pool twap (from secondAgo to now)
    uint32 public secondsAgo;

    // the twap max deviation acepted (in 10_000th)
    uint256 public twapDelta;

    // any ETH left-over in this contract (from swap in the end of liquidity range)
    mapping(address => uint256) public sweepBalanceOf;

    // running cumulative sum of ETH left-over
    uint256 public sweepBalance;

    //*********************************************************************//
    // --------------------- internal stored properties ------------------ //
    //*********************************************************************//

    /**
     * @notice The minted amount, min twap quote and reserved rate
     *
     * @dev    This is a mutex 1-x-1. This serves as common mutex for both 3
     *         variable below, unless one of the amounts > uint120 max (then the
     *         3 mutexes are used instead). The reserved rate max
     *         is 10_000 per protocol constraint.
     */
    uint256 internal mutexCommon = 1;

    /**
     * @notice The current reserved rate
     *
     * @dev    This is a mutex 1-x-1
     */
    uint256 internal mutexReservedRate = 1;

    /**
     * @notice The min swap quote (including slippage), from frontend or twap
     *
     * @dev    This is a mutex 1-x-1
     */
    uint256 internal mutexSwapQuote = 1;

    /**
     * @notice Are we using 1 or 3 mutexes?
     *
     * @dev    This is a mutex 1-x-1
     */
    uint256 internal useThreeMutexes = 1;

    /**
     * @dev No other logic besides initializing the immutables
     */
    constructor(
        IERC20 _projectToken,
        IWETH9 _weth,
        IUniswapV3Pool _pool,
        uint32 _secondsAgo,
        uint256 _twapDelta,
        IJBPayoutRedemptionPaymentTerminal3_1 _terminal,
        IJBController3_1 _controller
    ) {
        PROJECT_TOKEN = _projectToken;
        POOL = _pool;
        TERMINAL = _terminal;
        TERMINAL_STORE = _terminal.store();
        CONTROLLER = _controller;
        PROJECT_TOKEN_IS_TOKEN0 = address(_projectToken) < address(_weth);
        WETH = _weth;
        secondsAgo = _secondsAgo;
        twapDelta = _twapDelta;
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
        override
        returns (uint256 weight, string memory memo, JBPayDelegateAllocation[] memory delegateAllocations)
    {
        // Access control as minting is authorized to this delegate
        if (msg.sender != TERMINAL_STORE) revert JuiceBuyback_Unauthorized();

        // Find the total number of tokens to mint, as a fixed point number with 18 decimals
        uint256 _tokenCount = mulDiv18(_data.amount.value, _data.weight);

        // Get a quote based on either the uni SDK quote or a twap from the pool
        uint256 _swapAmountOut;

        // todo: fix with metadata parsing lib
        if (_data.metadata.length >= 128) {
            // Unpack the quote from the pool, given by the frontend - this one takes precedence on the twap
            // as it should be closer to the current pool state, if not, use the twap
            (,, uint256 _quote, uint256 _slippage) = abi.decode(_data.metadata, (bytes32, bytes32, uint256, uint256));
            _swapAmountOut = _quote - (_quote * _slippage / SLIPPAGE_DENOMINATOR);
        } else {
            _swapAmountOut = _getQuote(_data.amount.value);
        }

        // If the minimum amount received from swapping is greather than received when minting, use the swap pathway
        if (_tokenCount < _swapAmountOut) {
            // Pass the quotes and reserve rate via a mutex
            if (_tokenCount > type(uint120).max || _swapAmountOut > type(uint120).max) {
                // If the amount is too big, use the 3 mutexes (use common mutex for minted token, see unpacking logic)
                mutexCommon = _tokenCount;
                mutexReservedRate = _data.reservedRate;
                mutexSwapQuote = _swapAmountOut;

                // Signal the 3 mutexes use
                unchecked {
                    ++useThreeMutexes;
                }
            } else {
                // Otherwise, only use the common mutex
                mutexCommon = _tokenCount | (_swapAmountOut << 120) | (_data.reservedRate << 240);
            }

            // Return this delegate as the one to use, and do not mint from the terminal
            delegateAllocations = new JBPayDelegateAllocation[](1);
            delegateAllocations[0] =
                JBPayDelegateAllocation({delegate: IJBPayDelegate(this), amount: _data.amount.value});

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
    function didPay(JBDidPayData calldata _data) external payable override {
        // Access control as minting is authorized to this delegate
        if (msg.sender != address(TERMINAL)) revert JuiceBuyback_Unauthorized();

        // Retrieve and reset the common mutex
        uint256 _commonMutex = mutexCommon;
        mutexCommon = 1;

        uint256 _tokenCount;
        uint256 _swapMinAmountOut;
        uint256 _reservedRate;

        // Check if it was really the 3 packed or if the 3 mutexes need to be used (didPay called iff _tokenCount < _swapAmountOut)
        if (useThreeMutexes != 1) {
            _tokenCount = _commonMutex;
            _reservedRate = mutexReservedRate;
            _swapMinAmountOut = mutexSwapQuote;

            // reset mutexes
            mutexReservedRate = 1;
            mutexSwapQuote = 1;
            useThreeMutexes = 1;
        } else {
            // Max 120 bits for token count, 120 bits for min swap amount out, 16 bits for reserved rate
            _tokenCount = _commonMutex & type(uint120).max;
            _swapMinAmountOut = _commonMutex >> 120 & type(uint120).max;
            _reservedRate = _commonMutex >> 240;
        }

        // Try swapping
        uint256 _amountReceived = _swap(_data, _swapMinAmountOut, _reservedRate);

        // If swap failed, mint instead, with the original weight + add to balance the token in
        if (_amountReceived == 0) _mint(_data, _tokenCount);

        // Track any new eth left-over
        if (address(this).balance > 0 && address(this).balance != sweepBalance) {
            sweepBalanceOf[_data.beneficiary] += address(this).balance - sweepBalance;

            emit BuybackDelegate_PendingSweep(_data.beneficiary, address(this).balance - sweepBalance);

            sweepBalance = address(this).balance;
        }
    }

    /**
     * @notice The Uniswap V3 pool callback (where token transfer should happens)
     *
     * @dev    Slippage controle is achieved here
     */
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external override {
        // Check if this is really a callback
        if (msg.sender != address(POOL)) revert JuiceBuyback_Unauthorized();

        // Unpack the data
        (uint256 _minimumAmountReceived) = abi.decode(data, (uint256));

        // delta is in regard of the pool balance (positive = pool need to receive)
        uint256 _amountToSendToPool = PROJECT_TOKEN_IS_TOKEN0 ? uint256(amount1Delta) : uint256(amount0Delta);
        uint256 _amountReceivedForBeneficiary =
            PROJECT_TOKEN_IS_TOKEN0 ? uint256(-amount0Delta) : uint256(-amount1Delta);

        // Revert if slippage is too high
        if (_amountReceivedForBeneficiary < _minimumAmountReceived) revert JuiceBuyback_MaximumSlippage();

        // Wrap and transfer the WETH to the pool
        WETH.deposit{value: _amountToSendToPool}();
        WETH.transfer(address(POOL), _amountToSendToPool);
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
        returns (uint256 reclaimAmount, string memory memo, JBRedemptionDelegateAllocation[] memory delegateAllocations)
    {
        return (_data.reclaimAmount.value, _data.memo, delegateAllocations);
    }

    /**
     * @notice Increase the period over which the twap is computed
     *
     * @param  _newSecondsAgo the new period
     */
    function increaseSecondsAgo(uint32 _newSecondsAgo) external onlyOwner {
        uint32 _oldSecondsAgo = secondsAgo;

        if (_newSecondsAgo <= _oldSecondsAgo) revert JuiceBuyback_NewSecondsAgoTooLow();

        secondsAgo = _newSecondsAgo;

        emit BuybackDelegate_SecondsAgoIncrease(_oldSecondsAgo, _newSecondsAgo);
    }

    /**
     * @notice Set the maximum deviation allowed between amount received and twap
     *
     * @param  _newDelta the new delta, in 10_000th
     */
    function setTwapDelta(uint256 _newDelta) external onlyOwner {
        uint256 _oldDelta = twapDelta;

        twapDelta = _newDelta;

        emit BuybackDelegate_TwapDeltaChanged(_oldDelta, _newDelta);
    }

    /**
     * @notice Sweep the eth left-over in this contract
     */
    function sweep(address _beneficiary) external {
        // The beneficiary ETH balance in this contract leftover
        uint256 _balance = sweepBalanceOf[_beneficiary];

        // If no balance, don't do anything
        if (_balance == 0) return;

        // Reset beneficiary balance
        sweepBalanceOf[_beneficiary] = 0;

        // Keep the contract balance up to date
        sweepBalance = address(this).balance - _balance;

        // Send the eth to the beneficiary
        (bool _success,) = payable(_beneficiary).call{value: _balance}("");
        if (!_success) revert JuiceBuyback_TransferFailed();

        emit BuybackDelegate_PendingSweep(_beneficiary, 0);
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
    function _getQuote(uint256 _amountIn) internal view returns (uint256 _amountOut) {
        // If non-existing or non-initialized pool, quote 0
        try POOL.slot0() returns (uint160, int24, uint16, uint16, uint16, uint8, bool unlocked) {
            // non initialized?
            if (!unlocked) return 0;
        } catch {
            // invalid address or not deployed yet?
            return 0;
        }

        // Get the twap tick
        (int24 arithmeticMeanTick,) = OracleLibrary.consult(address(POOL), secondsAgo);

        // Get a quote based on this twap tick
        _amountOut =
            OracleLibrary.getQuoteAtTick(arithmeticMeanTick, uint128(_amountIn), address(WETH), address(PROJECT_TOKEN));

        // Return the lowest twap accepted
        _amountOut -= _amountOut * twapDelta / SLIPPAGE_DENOMINATOR;
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
    function _swap(JBDidPayData calldata _data, uint256 _minimumReceivedFromSwap, uint256 _reservedRate)
        internal
        returns (uint256 _amountReceived)
    {
        // Pass the token and min amount to receive as extra data
        try POOL.swap({
            recipient: address(this),
            zeroForOne: !PROJECT_TOKEN_IS_TOKEN0,
            amountSpecified: int256(_data.amount.value),
            sqrtPriceLimitX96: PROJECT_TOKEN_IS_TOKEN0 ? TickMath.MAX_SQRT_RATIO - 1 : TickMath.MIN_SQRT_RATIO + 1,
            data: abi.encode(_minimumReceivedFromSwap)
        }) returns (int256 amount0, int256 amount1) {
            // Swap succeded, take note of the amount of PROJECT_TOKEN received (negative as it is an exact input)
            _amountReceived = uint256(-(PROJECT_TOKEN_IS_TOKEN0 ? amount0 : amount1));
        } catch {
            // implies _amountReceived = 0 -> will later mint when back in didPay
            return _amountReceived;
        }

        // The amount to send to the beneficiary
        uint256 _nonReservedTokens = mulDiv(
            _amountReceived, JBConstants.MAX_RESERVED_RATE - _reservedRate, JBConstants.MAX_RESERVED_RATE
        );

        // The amount to add to the reserved token
        uint256 _reservedTokens = _amountReceived - _nonReservedTokens;

        // Send the non-reserved token to the beneficiary (if any / reserved rate is not max)
        if (_nonReservedTokens != 0) PROJECT_TOKEN.transfer(_data.beneficiary, _nonReservedTokens);
        // If there are reserved token, add them to the reserve
        if (_reservedTokens != 0) {
            // Mint the reserved token with this address as beneficiary -> result: _amountReceived-reserved here, reservedToken in reserve
            CONTROLLER.mintTokensOf({
                projectId: _data.projectId,
                tokenCount: _amountReceived,
                beneficiary: address(this),
                memo: _data.memo,
                preferClaimedTokens: false,
                useReservedRate: true
            });

            // Burn all the token received here (kept as reserved from the swap + minted just above)
            // ie when _preferClaimed is true, burn starts with the claimed token, then continue with unclaimed ones
            CONTROLLER.burnTokensOf({
                holder: address(this),
                projectId: _data.projectId,
                tokenCount: _amountReceived,
                memo: "",
                preferClaimedTokens: true
            });
        }

        emit BuybackDelegate_Swap(_data.projectId, _data.amount.value, _amountReceived);
    }

    /**
     * @notice Mint the token out, sending back the token in the terminal
     *
     * @param  _data the didPayData passed by the terminal
     * @param  _amount the amount of token out to mint
     */
    function _mint(JBDidPayData calldata _data, uint256 _amount) internal {
        // Mint to the beneficiary with the fc reserve rate
        CONTROLLER.mintTokensOf({
            projectId: _data.projectId,
            tokenCount: _amount,
            beneficiary: _data.beneficiary,
            memo: _data.memo,
            preferClaimedTokens: _data.preferClaimedTokens,
            useReservedRate: true
        });

        // Send the eth back to the terminal balance
        TERMINAL.addToBalanceOf{value: _data.amount.value}(_data.projectId, _data.amount.value, JBTokens.ETH, "", "");

        emit BuybackDelegate_Mint(_data.projectId);
    }

    //*********************************************************************//
    // ---------------------- peripheral functions ----------------------- //
    //*********************************************************************//

    function supportsInterface(bytes4 _interfaceId) public view override(ERC165, IERC165) returns (bool) {
        return _interfaceId == type(IJBFundingCycleDataSource).interfaceId
            || _interfaceId == type(IJBPayDelegate).interfaceId || super.supportsInterface(_interfaceId);
    }
}
