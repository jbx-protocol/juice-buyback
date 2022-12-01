// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;


import '@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBFundingCycleDataSource.sol';
import '@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBPayDelegate.sol';
import '@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBPayoutRedemptionPaymentTerminal.sol';
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

contract DataSourceDelegate is IJBFundingCycleDataSource, IJBPayDelegate, IUniswapV3SwapCallback {
  //*********************************************************************//
  // --------------------------- custom errors ------------------------- //
  //*********************************************************************//

  //*********************************************************************//
  // --------------------------- unherited events----------------------- //
  //*********************************************************************//

  //*********************************************************************//
  // --------------------- private constant properties ----------------- //
  //*********************************************************************//

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

  //*********************************************************************//
  // --------------------- public stored properties -------------------- //
  //*********************************************************************//

  //*********************************************************************//
  // --------------------- private stored properties ------------------- //
  //*********************************************************************//

  /**
    @notice
    A temporary storage of an eventual amount of token received if swapping is privilegied.
    This storage slot is reset at the end of the transaction (ie 1-X-1 as this is the cheapest mutex)
  */
  uint256 private _swapTokenCount = 1;

  /**
    @notice
    A temporary storage of an eventual amount of token received if minting is privilegied.
    This storage slot is reset at the end of the transaction (ie 1-X-1)
  */
  uint256 private _issueTokenCount = 1;

  constructor(IERC20 _projectToken, IERC20 _terminalToken, IUniswapV3Pool _pool, IJBPayoutRedemptionPaymentTerminal _jbxTerminal) {
    projectToken = _projectToken;
    terminalToken = _terminalToken;
    pool = _pool;
    jbxTerminal = _jbxTerminal;
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
        // Find the total number of tokens to mint, as a fixed point number with as many decimals as `weight` has.
        uint256 tokenCount = PRBMath.mulDiv(_data.amount.value, _data.weight, 10**_data.amount.decimals);

        // Get the net amount (without reserve rate), store in _mintTokenCount

        // Compare with the quote from the pool, store in _swapTokenCount

        // If _mintTokenCount > _swapTokenCount, return weight=_data.weight and no delegateAllocations

        // If _mintTokenCount < _swapTokenCount, return weight=0 and delegateAllocations for the net amount
        // in the swap path, mint for reserved rate too!

    }

    /**
        @notice
        Delegate to either swap or mint to the beneficiary (the mint to reserved being done by the delegate function, via
        the weight).
        @param _data the delegate data passed by the terminal
    */
    function didPay(JBDidPayData calldata _data) external payable override {
        // Compare _swapTokenCount and _issueTokenCount
        // If swap:
        // try swap with the limit, success -> ok; catch -> mint instead (max slippage reached)
        // Mint for the reserve? Or part of the swap?
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