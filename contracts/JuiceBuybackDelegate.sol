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

contract JuiceBuybackDelegate is IJBFundingCycleDataSource, IJBPayDelegate, IUniswapV3SwapCallback, Ownable {
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
      (uint256 _quote, uint256 _slippage) = abi.decode(_data.metadata, (uint256, uint256));

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
      used only if the fc reserved rate is the maximum

      @param _data the delegate data passed by the terminal
  */
  function didPay(JBDidPayData calldata _data) external payable override {
    // Retrieve the number of token created if minting and reset the mutex
    uint256 _tokenCount = _mintedAmount;
    _mintedAmount = 1;

    // The minimum amount of token received if swapping
    (uint256 _quote, uint256 _slippage) = abi.decode(_data.metadata, (uint256, uint256));
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
// negative == sent by the pool, positive == must be received by the pool

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
      // _amountReceived = 0 -> will later mint

      // Return the tokenIn to the terminal
      IJBPaymentTerminal(msg.sender).addToBalanceOf(_data.projectId, _data.amount.value, _data.amount.token, "", new bytes(0));
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
      JBConstants.MAX_RESERVED_RATE - _reservedRate,
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

  function _getReservedRate(uint256 _projectId) internal view returns(uint256 _reservedRate) {
    // Get the reserved rate configuration
    ReservedRateConfiguration storage _reservedRateConfiguration = reservedRateOf[_projectId];


    IJBFundingCycleBallot ballot = ballotOf[_projectId];

    // No ballot to use
    if(address(ballot) == address(0)) return _reservedRateConfiguration.rateAfter;

    JBBallotState _currentState = ballot.stateOf({
      _projectId: _projectId,
      _configuration: _reservedRateConfiguration.reconfigurationTime,
      _start: block.timestamp
    });

    if(_currentState == JBBallotState.Approved) _reservedRate = _reservedRateConfiguration.rateAfter;
    else  _reservedRate = _reservedRateConfiguration.rateBefore;
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

  /**
  @notice
  Set the reserved rate used by this delegate

  TODO: add fc constraint / ballot

  */
  function setReservedRateOf(uint256 _projectId, uint16 _reservedRate) external onlyOwner {
    if(_reservedRate > JBConstants.MAX_RESERVED_RATE) revert JuiceBuyback_InvalidReservedRate();

    IJBFundingCycleBallot ballot = ballotOf[_projectId];

    // No ballot to use
    if(address(ballot) == address(0)) reservedRateOf[_projectId].rateAfter = _reservedRate;
    else {
      // Create a mem working copy
      ReservedRateConfiguration memory _reservedRateStruct = reservedRateOf[_projectId];

      _reservedRateStruct.rateBefore = _reservedRateStruct.rateAfter;
      _reservedRateStruct.rateAfter = _reservedRate;
      _reservedRateStruct.reconfigurationTime = uint224(block.timestamp);

      reservedRateOf[_projectId] = _reservedRateStruct;
    }

  }

  function addBallotTo(uint256 _projectId, IJBFundingCycleBallot _ballot) external onlyOwner {
    ballotOf[_projectId] = _ballot;
  }
}