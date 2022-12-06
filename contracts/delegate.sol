// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import '@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBController.sol';
import '@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBFundingCycleDataSource.sol';
import '@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBFundingCycleStore.sol';
import '@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBPayDelegate.sol';
import '@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBPayoutRedemptionPaymentTerminal.sol';
import '@jbx-protocol/juice-contracts-v3/contracts/libraries/JBConstants.sol';
import '@jbx-protocol/juice-contracts-v3/contracts/libraries/JBFundingCycleMetadataResolver.sol';
import '@jbx-protocol/juice-contracts-v3/contracts/libraries/JBTokens.sol'; 
import '@jbx-protocol/juice-contracts-v3/contracts/structs/JBDidPayData.sol';
import '@jbx-protocol/juice-contracts-v3/contracts/structs/JBPayParamsData.sol';

import '@openzeppelin/contracts/interfaces/IERC20.sol';

import '@paulrberg/contracts/math/PRBMath.sol';

import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol';
import '@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol';

import './interfaces/external/IWETH9.sol';

/**
  @title
  Delegate buyback
  
  @notice
  Based on the amount received by minting versus swapped on Uniswap V3, provide the best
  quote for the user when contributing to a project.
*/

contract JuiceBuyback is IJBFundingCycleDataSource, IJBPayDelegate, IUniswapV3SwapCallback {
  using JBFundingCycleMetadataResolver for JBFundingCycle;
  //*********************************************************************//
  // --------------------------- custom errors ------------------------- //
  //*********************************************************************//
  error JuiceBuyback_Unauthorized();

  //*********************************************************************//
  // --------------------------- unherited events----------------------- //
  //*********************************************************************//

  //*********************************************************************//
  // --------------------- private constant properties ----------------- //
  //*********************************************************************//

  /**
    @notice
    Address project token < address terminal token ?
  */
  bool private immutable _projectTokenIsZero;

  /**
    @notice
    The unit of the max slippage (expressed in 1/10000th)
  */
  uint256 private constant SLIPPAGE_DENOMINATOR = 10000;

  //*********************************************************************//
  // --------------------- public constant properties ------------------ //
  //*********************************************************************//

  /**
    @notice
    The other token paired with the project token in the Uniswap pool/the terminal currency.
  */
  IERC20 public immutable terminalToken;

  /**
    @notice
    The project token address
  */
  IERC20 public immutable projectToken;

  /**
    @notice
    The uniswap pool corrsponding to the project token-other token market
  */
  IUniswapV3Pool public immutable pool;

  /**
    @notice
    The projectId terminal using this extension
  */
  IJBPayoutRedemptionPaymentTerminal public immutable jbxTerminal;

  /**
    @notice
    The WETH contract
  */
  IWETH9 public immutable weth;

  //*********************************************************************//
  // --------------------- public stored properties -------------------- //
  //*********************************************************************//

  /**
    @notice
    The actual reserved rate (the fc needs to have a max reserved rate for this delegate to run)
  */
  uint256 public reservedRate;

  //*********************************************************************//
  // --------------------- private stored properties ------------------- //
  //*********************************************************************//

  /**
    @notice
    The amount of token created if minted is prefered
    
    @dev
    This is a mutex 1-x-1
  */
  uint256 private _mintedAmount;

  constructor(IERC20 _projectToken, IERC20 _terminalToken, IUniswapV3Pool _pool, IJBPayoutRedemptionPaymentTerminal _jbxTerminal, IWETH9 _weth) {
    projectToken = _projectToken;
    terminalToken = _terminalToken;
    pool = _pool;
    jbxTerminal = _jbxTerminal;
    _projectTokenIsZero = address(_projectToken) < address(_terminalToken);
    weth = _weth;
  }
    
  //*********************************************************************//
  // ---------------------- external functions ------------------------- //
  //*********************************************************************//

  /**
    @notice
    The datasource implementation
    @dev   
    @param _data the data passed to the data source in terminal.pay(..). _data.metadata need to have the Uniswap quote
    @return weight the weight to use (the one passed if not max reserved rate, 0 if swapping or the one corresponding
            to the reserved token to mint if minting)
    @return memo the original memo passed
    @return delegateAllocations The amount to send to delegates instead of adding to the local balance.
  */
  function payParams(JBPayParamsData calldata _data)
    external
    override
    returns (
      uint256 weight,
      string memory memo,
      JBPayDelegateAllocation[] memory delegateAllocations
    )
    {
      // If the funding cycle reserved rate is not the max, do not use the delegate
      if (_data.reservedRate != JBConstants.MAX_RESERVED_RATE) {
        return (_data.weight, _data.memo, new JBPayDelegateAllocation[](0));
      }

      // Find the total number of tokens to mint, as a fixed point number with as many decimals as `weight` has.
      uint256 _tokenCount = PRBMath.mulDiv(_data.amount.value, _data.weight, 10**_data.amount.decimals);

      // Unpack the quote from the pool
      (uint256 _quote, uint256 _slippage) = abi.decode(_data.metadata, (uint256, uint256));

      // If the amount minted is bigger than the lowest received when swapping, use the mint pathway
      if (_tokenCount >= _quote * _slippage / SLIPPAGE_DENOMINATOR) {
        _mintedAmount = _tokenCount;
      }

      delegateAllocations = new JBPayDelegateAllocation[](1);
      delegateAllocations[0] = JBPayDelegateAllocation({
          delegate: IJBPayDelegate(this),
          amount: _data.amount.value
      });

      return (0, _data.memo, delegateAllocations);
    }

  /**
      @notice
      Delegate to either swap to the beneficiary (the mint to reserved being done by the delegate function, via
      the weight) - this function is only called if swapping gather more token (delegate is bypassed if not)
      @param _data the delegate data passed by the terminal
  */
  function didPay(JBDidPayData calldata _data) external payable override {

    uint256 _amountReceived;

    // The number of token created if minting
    uint256 _tokenCount = _mintedAmount;
    delete _mintedAmount; // reset the mutex

    // The number of token received if swapping
    (uint256 _quote, uint256 _slippage) = abi.decode(_data.metadata, (uint256, uint256));


    // Pull and approve token for swap
    if(_data.amount.token != JBTokens.ETH) {
      IERC20(_data.amount.token).transferFrom(msg.sender, address(this), _data.amount.value);
      IERC20(_data.amount.token).approve(address(pool), _data.amount.value);
    } else {
      // Wrap and approve weth balance
      weth.deposit{value: _data.amount.value}();
      weth.approve(address(pool), _data.amount.value);
    }


// if quote > mint: swap; else: mint

  
  }

  function redeemParams(JBRedeemParamsData calldata _data)
      external
      override
  returns (
          uint256 reclaimAmount,
          string memory memo,
          JBRedemptionDelegateAllocation[] memory delegateAllocations
  ) {}

  /**
    @notice
    The Uniswap V3 pool callback (where token transfer should happens)
    @dev the twap-spot deviation is checked in this callback.
  */
  function uniswapV3SwapCallback(
    int256 amount0Delta,
    int256 amount1Delta,
    bytes calldata data
  ) external override {

    // Check if this is really a callback
    if(msg.sender != address(pool)) revert JuiceBuyback_Unauthorized();

    (address _recipient, uint256 _minimumAmountReceived) = abi.decode(data, (address, uint256));

    // If _minimumAmountReceived > amount0 or 1, revert max slippage (this is handled by the try-catch)

    // Pull fund from _recipient + treat eth case
  }

  //*********************************************************************//
  // ---------------------- internal functions ------------------------- //
  //*********************************************************************//

  /**
    @notice
    Swap the token out and a part of the overflow, for the beneficiary and the reserved tokens
    @dev
    Only a share of the token in are swapped and then sent to the beneficiary. The corresponding
    token are swapped using a part of the project treasury. Both token in are used via an overflow
    allowance.
    The reserved token are received in this contract, burned and then minted for the reserved token.
    @param _data the didPayData passed by the terminal
  */
  function _swap(JBDidPayData calldata _data) internal {
        // Try swapping, no price limit as slippage is tested on amount received.
    // Pass the terminal and min amount received as data
    try pool.swap({
      recipient: address(this),
        zeroForOne: !_projectTokenIsZero,
        amountSpecified: int256(_data.amount.value),
        sqrtPriceLimitX96: 0,
        data: abi.encode(msg.sender, _quote * _slippage / SLIPPAGE_DENOMINATOR)
    }) returns (int256 amount0, int256 amount1) {
      // Swap succeded, take note of the amount of projectToken received
      _amountReceived = uint256(!_projectTokenIsZero ? amount0 : amount1);
    
    } catch {
    
    }
  }

    function _mint(JBDidPayData calldata _data, uint256 _amount) internal {
          // If swap is not successfull, mint the token to the beneficiary

      IJBController controller = IJBController(jbxTerminal.directory().controllerOf(_data.projectId));

      // Get the net amount (without reserve rate), to send to beneficiary
      uint256 _nonReservedToken = PRBMath.mulDiv(
        _amount,
        JBConstants.MAX_RESERVED_RATE - reservedRate,
        JBConstants.MAX_RESERVED_RATE);

      // Mint to the beneficiary the non reserved token
      controller.mintTokensOf({
        _projectId: _data.projectId,
        _tokenCount: _nonReservedToken,
        _beneficiary: _data.beneficiary,
        _memo: _data.memo,
        _preferClaimedTokens: _data.preferClaimedTokens,
        _useReservedRate: false
        });

      // Mint the reserved token
      controller.mintTokensOf({
        _projectId: _data.projectId,
        _tokenCount: _amount - _nonReservedToken,
        _beneficiary: _data.beneficiary,
        _memo: _data.memo,
        _preferClaimedTokens: _data.preferClaimedTokens,
        _useReservedRate: true
        });
  }

  //*********************************************************************//
  // ---------------------- peripheral functions ----------------------- //
  //*********************************************************************//

  function supportsInterface(bytes4 _interfaceId) external pure override returns (bool) {
    return
      _interfaceId == type(IJBFundingCycleDataSource).interfaceId ||
      _interfaceId == type(IJBPayDelegate).interfaceId;
  }

  //*********************************************************************//
  // ---------------------- setter functions --------------------------- //
  //*********************************************************************//
}