// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import '@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBController.sol';
import '@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBFundingCycleDataSource.sol';
import '@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBPayDelegate.sol';
import '@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBPayoutRedemptionPaymentTerminal.sol';
import '@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBFundingCycleBallot.sol';
import '@jbx-protocol/juice-contracts-v3/contracts/libraries/JBConstants.sol';
import '@jbx-protocol/juice-contracts-v3/contracts/libraries/JBFundingCycleMetadataResolver.sol';
import '@jbx-protocol/juice-contracts-v3/contracts/libraries/JBTokens.sol'; 
import '@jbx-protocol/juice-contracts-v3/contracts/structs/JBDidPayData.sol';
import '@jbx-protocol/juice-contracts-v3/contracts/structs/JBPayParamsData.sol';

import '@openzeppelin/contracts/interfaces/IERC20.sol';
import '@openzeppelin/contracts/access/Ownable.sol';

import '@paulrberg/contracts/math/PRBMath.sol';

import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol';
import '@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol';

import './interfaces/external/IWETH9.sol';

/**
	@custom:benediction DEVS BENEDICAT ET PROTEGAT CONTRACTVS MEAM

  @title
  Delegate buyback
  
  @notice
  Based on the amount received if minting versus swapped on Uniswap V3, provide the best
  quote for the user when contributing to a project.
*/

contract JuiceBuyback is IJBFundingCycleDataSource, IJBPayDelegate, IUniswapV3SwapCallback, Ownable {
  using JBFundingCycleMetadataResolver for JBFundingCycle;

  //*********************************************************************//
  // --------------------------- custom errors ------------------------- //
  //*********************************************************************//
  error JuiceBuyback_InvalidReservedRate();
  error JuiceBuyback_Unauthorized();
  error JuiceBuyback_MaximumSlippage();

  //*********************************************************************//
  // -----------------------------  events ----------------------------- //
  //*********************************************************************//

  struct ReservedRateConfiguration {
    uint224 reconfigurationTime; // time at which the reserved rate was reconfigured
    uint16 rateBefore; // reserved rate (expressed in 1/10000th) before reconfig
    uint16 rateAfter; // reserved rate (expressed in 1/10000th) after reconfig
  }

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
    The maximum reserved rate used by this delegate, passed as fc metadata (expressed in 1/200th)
  */
  uint256 public constant MAX_RESERVED_RATE = 200;

  /**
    @notice
    The other token paired with the project token in the Uniswap pool/the terminal currency.

    @dev
    In this context, this is the token in
  */
  IERC20 public immutable terminalToken;

  /**
    @notice
    The project token address

    @dev
    In this context, this is the token out
  */
  IERC20 public immutable projectToken;

  /**
    @notice
    The uniswap pool corresponding to the project token-other token market
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
  mapping(uint256=>ReservedRateConfiguration) public reservedRateOf;

  /**
    @notice
    The ballot used by a project
  */
  mapping(uint256=>IJBFundingCycleBallot) public ballotOf;

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

  /**
    @dev
    No other logic besides initializing the immutables
  */
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
      // If the funding cycle reserved rate is not the max, do not use the delegate (pass through)
      if (_data.reservedRate != JBConstants.MAX_RESERVED_RATE)
        return (_data.weight, _data.memo, new JBPayDelegateAllocation[](0));

      // Find the total number of tokens to mint, as a fixed point number with as many decimals as `weight` has.
      uint256 _tokenCount = PRBMath.mulDiv(_data.amount.value, _data.weight, 10**_data.amount.decimals);

      // Unpack the quote from the pool, given by the frontend
      (, , uint256 _quote, uint256 _slippage) = abi.decode(_data.metadata, (bytes32, bytes32, uint256, uint256));

      delegateAllocations = new JBPayDelegateAllocation[](1);

      // If the amount minted is bigger than the lowest received when swapping, use the mint pathway
      if (_tokenCount >= _quote * _slippage / SLIPPAGE_DENOMINATOR) {
        _mintedAmount = _tokenCount;

        delegateAllocations[0] = JBPayDelegateAllocation({
          delegate: IJBPayDelegate(this),
          amount: 0 // Leave the terminal token in the terminal
        });
      } else {
        delegateAllocations[0] = JBPayDelegateAllocation({
          delegate: IJBPayDelegate(this),
          amount: _data.amount.value // Take the terminal token for swapping it
        });
      }

      return (0, _data.memo, delegateAllocations);
    }

  /**
      @notice
      Delegate to either swap to the beneficiary or mint to the beneficiary

      @dev
      The reserved token are added by burning and minting them again, as this delegate is 
      used only if the fc reserved rate is the maximum. The actual reserved rate is in the
      fundingcycle metadata.

      @param _data the delegate data passed by the terminal
  */
  function didPay(JBDidPayData calldata _data) external payable override {
    // Retrieve the number of token created if minting and reset the mutex
    uint256 _tokenCount = _mintedAmount;
    _mintedAmount = 1;

    // The minimum amount of token received if swapping
    (, , uint256 _quote, uint256 _slippage) = abi.decode(_data.metadata, (bytes32, bytes32, uint256, uint256));
    uint256 _minimumReceivedFromSwap = _quote * _slippage / SLIPPAGE_DENOMINATOR;

    // Pick the appropriate pathway (swap vs mint)
    if (_minimumReceivedFromSwap > _tokenCount) {
      // Try swapping
      uint256 _amountReceived = _swap(_data, _minimumReceivedFromSwap);

      // If swap failed, mint instead, with the original weight + add to balance the token in
      if (_amountReceived == 0) _mint(_data, _tokenCount);
    } else _mint(_data, _tokenCount);

  }

  /**
    @notice
    The Uniswap V3 pool callback (where token transfer should happens)

    @dev
    Slippage controle is done here
  */
  function uniswapV3SwapCallback(
    int256 amount0Delta,
    int256 amount1Delta,
    bytes calldata data
  ) external override {
    // Check if this is really a callback
    if(msg.sender != address(pool)) revert JuiceBuyback_Unauthorized();

    // Unpack the data
    (address _terminal, address _token, uint256 _minimumAmountReceived) = abi.decode(data, (address, address, uint256));

    // Assign 0 and 1 accordingly
    uint256 _amountReceived = uint256(-(_projectTokenIsZero ? amount0Delta : amount1Delta));
    uint256 _amountToSend = uint256(-(_projectTokenIsZero ? amount1Delta : amount0Delta));

    // Revert if slippage is too high
    if (_amountReceived < _minimumAmountReceived) revert JuiceBuyback_MaximumSlippage();

    // Pull and transfer token to the pool
    if(_token != JBTokens.ETH) IERC20(_token).transferFrom(_terminal, address(pool), _amountToSend);
    else {
      // Wrap and transfer the weth to the pool
      weth.deposit{value: _amountToSend}();
      weth.transfer(address(pool), _amountToSend);
    }
  }

  function redeemParams(JBRedeemParamsData calldata _data)
    external
    override
    returns (
      uint256 reclaimAmount,
      string memory memo,
      JBRedemptionDelegateAllocation[] memory delegateAllocations
  ) {}

  //*********************************************************************//
  // ---------------------- internal functions ------------------------- //
  //*********************************************************************//

  /**
    @notice
    Swap the token in
    @dev
    The reserved token are received in this contract, burned and then minted for the reserved token.
    @param _data the didPayData passed by the terminal
    @param _minimumReceivedFromSwap the minimum amount received, to prevent slippage
  */
  function _swap(JBDidPayData calldata _data, uint256 _minimumReceivedFromSwap) internal returns(uint256 _amountReceived){

    // Pass the terminal, token and min amount to receive as extra data
    try pool.swap({
      recipient: address(this),
        zeroForOne: !_projectTokenIsZero,
        amountSpecified: int256(_data.amount.value),
        sqrtPriceLimitX96: 0,
        data: abi.encode(msg.sender, _data.amount.token, _minimumReceivedFromSwap)
    }) returns (int256 amount0, int256 amount1) {
      // Swap succeded, take note of the amount of projectToken received (negative as it is an exact input)
      _amountReceived = uint256(-(_projectTokenIsZero ? amount0 : amount1));
    } catch {
      // implies _amountReceived = 0 -> will later mint when back in didPay

      // Send the tokenIn back to the terminal balance
      IJBPaymentTerminal(msg.sender).addToBalanceOf
        {value: address(terminalToken) == JBTokens.ETH ? _data.amount.value : 0}
        (_data.projectId, _data.amount.value, _data.amount.token, "", new bytes(0));

      return _amountReceived;
    }

    // Get the net amount (without reserve), to send to beneficiary
    uint256 _reservedRate = _getReservedRate(_data.projectId);

    uint256 _nonReservedToken = PRBMath.mulDiv(
      _amountReceived,
      MAX_RESERVED_RATE - _reservedRate,
      MAX_RESERVED_RATE);

    // Send the non reserved token to the beneficiary (if any / reserved rate is not max)
    if(_nonReservedToken != 0) projectToken.transfer(_data.beneficiary, _nonReservedToken);

    // If there are reserved token, burn and mint them to the reserve
    if(_amountReceived - _nonReservedToken != 0) {
      // burn the reserved portion to mint it to the reserve (using the fc max reserved rate)
      IJBController controller = IJBController(jbxTerminal.directory().controllerOf(_data.projectId));

      controller.burnTokensOf({
        _holder: address(this),
        _projectId: _data.projectId,
        _tokenCount: _amountReceived - _nonReservedToken,
        _memo: '',
        _preferClaimedTokens: true
      });

      // Mint the reserved token straight to the reserve
      controller.mintTokensOf({
        _projectId: _data.projectId,
        _tokenCount: _amountReceived - _nonReservedToken,
        _beneficiary: _data.beneficiary,
        _memo: _data.memo,
        _preferClaimedTokens: _data.preferClaimedTokens,
        _useReservedRate: true
        });
    }
  }

  /**
    @notice
    Mint the token out, leaving token in in the terminal

    @param _data the didPayData passed by the terminal
    @param _amount the amount of token out to mint
  */
  function _mint(JBDidPayData calldata _data, uint256 _amount) internal {

    IJBController controller = IJBController(jbxTerminal.directory().controllerOf(_data.projectId));

    uint256 _reservedRate = _getReservedRate(_data.projectId);

    // Get the net amount (without reserve rate), to send to beneficiary
    uint256 _nonReservedToken = PRBMath.mulDiv(
      _amount,
      MAX_RESERVED_RATE - _reservedRate,
      MAX_RESERVED_RATE);

    // Mint to the beneficiary the non reserved token (if any)
    if(_nonReservedToken != 0)
      controller.mintTokensOf({
        _projectId: _data.projectId,
        _tokenCount: _nonReservedToken,
        _beneficiary: _data.beneficiary,
        _memo: _data.memo,
        _preferClaimedTokens: _data.preferClaimedTokens,
        _useReservedRate: false
      });

    // Mint the reserved token
    if(_amount - _nonReservedToken != 0)
      controller.mintTokensOf({
        _projectId: _data.projectId,
        _tokenCount: _amount - _nonReservedToken,
        _beneficiary: _data.beneficiary,
        _memo: _data.memo,
        _preferClaimedTokens: _data.preferClaimedTokens,
        _useReservedRate: true
      });
  }

  function _getReservedRate(uint256 _projectId) internal view returns(uint256 _reservedRate) {
    // burn the reserved portion to mint it to the reserve (using the fc max reserved rate)
    IJBController _controller = IJBController(jbxTerminal.directory().controllerOf(_projectId));

    (, JBFundingCycleMetadata memory _metadata) = _controller.currentFundingCycleOf(_projectId);

    _reservedRate = _metadata.metadata;

    // If invalid reserved rate, use no reserve
    if(_reservedRate > MAX_RESERVED_RATE) _reservedRate = 0;
  }

  //*********************************************************************//
  // ---------------------- peripheral functions ----------------------- //
  //*********************************************************************//

  function supportsInterface(bytes4 _interfaceId) external pure override returns (bool) {
    return
      _interfaceId == type(IJBFundingCycleDataSource).interfaceId ||
      _interfaceId == type(IJBPayDelegate).interfaceId;
  }
}