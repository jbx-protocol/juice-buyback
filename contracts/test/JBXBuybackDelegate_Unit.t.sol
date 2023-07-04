// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import '../interfaces/external/IWETH9.sol';
import './helpers/TestBaseWorkflowV3.sol';

import '@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBController.sol';
import '@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBFundingCycleStore.sol';
import '@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBFundingCycleBallot.sol';
import '@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBFundingCycleDataSource.sol';
import '@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBOperatable.sol';
import '@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBPayDelegate.sol';
import '@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBRedemptionDelegate.sol';
import '@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBPayoutRedemptionPaymentTerminal.sol';
import '@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBSingleTokenPaymentTerminalStore.sol';
import '@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBToken.sol';
import '@jbx-protocol/juice-contracts-v3/contracts/libraries/JBConstants.sol';
import '@jbx-protocol/juice-contracts-v3/contracts/libraries/JBCurrencies.sol';
import '@jbx-protocol/juice-contracts-v3/contracts/libraries/JBFundingCycleMetadataResolver.sol';
import '@jbx-protocol/juice-contracts-v3/contracts/libraries/JBOperations.sol';
import '@jbx-protocol/juice-contracts-v3/contracts/libraries/JBTokens.sol';
import '@jbx-protocol/juice-contracts-v3/contracts/structs/JBFundingCycle.sol';

import '@paulrberg/contracts/math/PRBMath.sol';
import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol';
import '@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol';


import 'forge-std/Test.sol';

import '../JBXBuybackDelegate.sol';

/**
 * @notice Unit tests for the JBXBuybackDelegate contract.
 *
 */
contract TestJBXBuybackDelegate_Units is Test {
  ForTest_JBXBuybackDelegate delegate;

  IERC20 projectToken;
  IWETH9 weth;
  IUniswapV3Pool pool;
  IJBPayoutRedemptionPaymentTerminal3_1 jbxTerminal;
  IJBProjects projects;
  IJBOperatorStore operatorStore;

  address terminalStore;

  address dude;

  uint32 secondsAgo = 100;
  uint256 twapDelta = 100;

  // Create payParams data
  JBPayParamsData payParams = JBPayParamsData({
    terminal: jbxTerminal,
    payer: dude,
    amount: JBTokenAmount({
      token: address(weth),
      value: 1 ether,
      decimals: 18,
      currency: 1
    }),
    projectId: 69,
    currentFundingCycleConfiguration: 0,
    beneficiary: dude,
    weight: 69,
    reservedRate: 69,
    memo: 'myMemo',
    metadata: ''
  });

  JBDidPayData didPayData = JBDidPayData({
    payer: dude,
    projectId: 69,
    currentFundingCycleConfiguration: 0,
    amount: JBTokenAmount({
      token: address(weth),
      value: 1 ether,
      decimals: 18,
      currency: 1
    }),
    forwardedAmount:
      JBTokenAmount({
        token: address(weth),
        value: 1 ether,
        decimals: 18,
        currency: 1
      }),
    projectTokenCount: 69,
    beneficiary: dude,
    preferClaimedTokens: true,
    memo: 'myMemo',
    metadata: ''
  });

  function setUp() external {

    projectToken = IERC20(makeAddr('projectToken'));
    vm.etch(address(projectToken), '6969');

    weth = IWETH9(makeAddr('weth'));
    vm.etch(address(weth), '6969');

    pool = IUniswapV3Pool(makeAddr('pool'));
    vm.etch(address(pool), '6969');

    jbxTerminal = IJBPayoutRedemptionPaymentTerminal3_1(makeAddr('jbxTerminal'));
    vm.etch(address(jbxTerminal), '6969');

    projects = IJBProjects(makeAddr('projects'));
    vm.etch(address(projects), '6969');

    operatorStore = IJBOperatorStore(makeAddr('operatorStore'));
    vm.etch(address(operatorStore), '6969');

    terminalStore = makeAddr('terminalStore');

    dude = makeAddr('dude');

    vm.mockCall(address(jbxTerminal), abi.encodeCall(jbxTerminal.store, ()), abi.encode(terminalStore));

    delegate = new ForTest_JBXBuybackDelegate({
      _projectToken: projectToken,
      _weth: weth,
      _pool: pool,
      _secondsAgo: secondsAgo,
      _twapDelta: twapDelta,
      _jbxTerminal: jbxTerminal,
      _projects: projects,
      _operatorStore: operatorStore
    });
  }
  
  /**
   * @notice Test payParams with swap pathway and a quote
   *
   * @dev    _tokenCount == weight, as we use a value of 1.
   */
  function test_payParams_swapWithQuote(uint256 _tokenCount, uint256 _swapOutCount, uint256 _slippage) public {
    
    _tokenCount = bound(_tokenCount, 1, type(uint120).max);
    _swapOutCount = bound(_swapOutCount, 1, type(uint120).max);
    _slippage = bound(_slippage, 1, 10000);

    // Pass the quote as metadata
    bytes memory _metadata = abi.encode('', '', _swapOutCount, _slippage);

    // Set the relevant payParams data
    payParams.weight = _tokenCount;
    payParams.metadata = _metadata;

    // Returned values to catch:
    JBPayDelegateAllocation[] memory _allocationsReturned;
    string memory _memoReturned;
    uint256 _weightReturned;

    // Test: call payParams
    vm.prank(terminalStore);
    ( _weightReturned, _memoReturned, _allocationsReturned) = delegate.payParams(payParams);

    // Mint pathway if more token received when minting:
    if(_tokenCount >= _swapOutCount - (_swapOutCount * _slippage / 10000)) {
      // No delegate allocation returned
      assertEq(_allocationsReturned.length, 0);

      // weight unchanged
      assertEq(_weightReturned, _tokenCount);

      // mutex unchanged
      assertEq(delegate.ForTest_mutexCommon(), 1);
      assertEq(delegate.ForTest_mutexReservedRate(), 1);
      assertEq(delegate.ForTest_mutexTwapQuote(), 1);
    }

    // Swap pathway (set the mutexes and return the delegate allocation)
    else {
      assertEq(_allocationsReturned.length, 1);
      assertEq(address(_allocationsReturned[0].delegate), address(delegate));
      assertEq(_allocationsReturned[0].amount, 1 ether);

      assertEq(_weightReturned, 0);

      // Check the mutexes (nothing should be > uint120 -> only one mutex used)
      assertEq(delegate.ForTest_mutexCommon(), _tokenCount | (_swapOutCount - (_swapOutCount * _slippage / 10000)) << 120 | payParams.reservedRate << 240);
      assertEq(delegate.ForTest_mutexReservedRate(), 1);
      assertEq(delegate.ForTest_mutexTwapQuote(), 1);
    }

    // Same memo in any case
    assertEq(_memoReturned, payParams.memo);
  }

  /**
   * @notice Test payParams with swap pathway using twap
   *
   * @dev    This bypass testing Uniswap Oracle lib by re-using the internal _getQuote
   */
  function test_payParams_swapWithTwap(uint256 _tokenCount  ) public {
    
    _tokenCount = bound(_tokenCount, 1, type(uint120).max);

    // Set the relevant payParams data
    payParams.weight = _tokenCount;
    payParams.metadata = '';

    // Mock the pool being unlocked
    vm.mockCall(address(pool), abi.encodeCall(pool.slot0, ()), abi.encode(0, 0, 0, 0, 0, 0, true));
    vm.expectCall(address(pool), abi.encodeCall(pool.slot0, ()));

    // Mock the pool's twap
    uint32[] memory _secondsAgos = new uint32[](2);
    _secondsAgos[0] = secondsAgo;
    _secondsAgos[1] = 0;

    uint160[] memory _secondPerLiquidity = new uint160[](2);
    _secondPerLiquidity[0] = 100;
    _secondPerLiquidity[1] = 1000;

    int56[] memory _tickCumulatives = new int56[](2);
    _tickCumulatives[0] = 100;
    _tickCumulatives[1] = 1000;

    vm.mockCall(address(pool), abi.encodeCall(pool.observe, (_secondsAgos)), abi.encode(_tickCumulatives, _secondPerLiquidity));
    vm.expectCall(address(pool), abi.encodeCall(pool.observe, (_secondsAgos)));

    // Returned values to catch:
    JBPayDelegateAllocation[] memory _allocationsReturned;
    string memory _memoReturned;
    uint256 _weightReturned;

    // Test: call payParams
    vm.prank(terminalStore);
    ( _weightReturned, _memoReturned, _allocationsReturned) = delegate.payParams(payParams);

    // Bypass testing uniswap oracle lib
    uint256 _twapAmountOut = delegate.ForTest_getQuote(1 ether);

    // Mint pathway if more token received when minting:
    if(_tokenCount >= _twapAmountOut) {
      // No delegate allocation returned
      assertEq(_allocationsReturned.length, 0);

      // weight unchanged
      assertEq(_weightReturned, _tokenCount);

      // mutex unchanged
      assertEq(delegate.ForTest_mutexCommon(), 1);
      assertEq(delegate.ForTest_mutexReservedRate(), 1);
      assertEq(delegate.ForTest_mutexTwapQuote(), 1);
    }

    // Swap pathway (set the mutexes and return the delegate allocation)
    else {
      assertEq(_allocationsReturned.length, 1);
      assertEq(address(_allocationsReturned[0].delegate), address(delegate));
      assertEq(_allocationsReturned[0].amount, 1 ether);

      assertEq(_weightReturned, 0);

      // Check the mutexes (nothing should be > uint120 -> only one mutex used)
      assertEq(delegate.ForTest_mutexCommon(), _tokenCount | _twapAmountOut << 120 | payParams.reservedRate << 240);
      assertEq(delegate.ForTest_mutexReservedRate(), 1);
      assertEq(delegate.ForTest_mutexTwapQuote(), 1);
    }

    // Same memo in any case
    assertEq(_memoReturned, payParams.memo);
  }

  /**
   * @notice Test payParams with a twap but locked pool, which should then mint
   */
  function test_payParams_swapWithTwapLockedPool(uint256 _tokenCount  ) public {
    
    _tokenCount = bound(_tokenCount, 1, type(uint120).max);

    // Set the relevant payParams data
    payParams.weight = _tokenCount;
    payParams.metadata = '';

    // Mock the pool being unlocked
    vm.mockCall(address(pool), abi.encodeCall(pool.slot0, ()), abi.encode(0, 0, 0, 0, 0, 0, false));
    vm.expectCall(address(pool), abi.encodeCall(pool.slot0, ()));

    // Returned values to catch:
    JBPayDelegateAllocation[] memory _allocationsReturned;
    string memory _memoReturned;
    uint256 _weightReturned;

    // Test: call payParams
    vm.prank(terminalStore);
    ( _weightReturned, _memoReturned, _allocationsReturned) = delegate.payParams(payParams);

    // No delegate allocation returned
    assertEq(_allocationsReturned.length, 0);

    // weight unchanged
    assertEq(_weightReturned, _tokenCount);

    // Same memo
    assertEq(_memoReturned, payParams.memo);

    // mutex unchanged
    assertEq(delegate.ForTest_mutexCommon(), 1);
    assertEq(delegate.ForTest_mutexReservedRate(), 1);
    assertEq(delegate.ForTest_mutexTwapQuote(), 1);
  }

  /**
   * @notice Test payParams with a quote or minted amount > uint120
   */
  function test_payParams_swapWithQuoteUsingThreeMutex(uint256 _tokenCount, uint256 _swapOutCount) public {
    
    _tokenCount = bound(_tokenCount, 1, type(uint256).max);

    _swapOutCount = bound(_swapOutCount, _tokenCount > type(uint120).max ? 1 : uint256(type(uint120).max) + 1, type(uint256).max);

    // Pass the quote as metadata, no slippage
    bytes memory _metadata = abi.encode('', '', _swapOutCount, 0);

    // Set the relevant payParams data
    payParams.weight = _tokenCount;
    payParams.metadata = _metadata;
    payParams.reservedRate = 69;

    // Returned values to catch:
    JBPayDelegateAllocation[] memory _allocationsReturned;
    string memory _memoReturned;
    uint256 _weightReturned;

    // Test: call payParams
    vm.prank(terminalStore);
    ( _weightReturned, _memoReturned, _allocationsReturned) = delegate.payParams(payParams);

    // Mint pathway if more token received when minting:
    if(_tokenCount >= _swapOutCount) {
      // No delegate allocation returned
      assertEq(_allocationsReturned.length, 0);

      // weight unchanged
      assertEq(_weightReturned, _tokenCount);
    }

    // Swap pathway (set the mutexes and return the delegate allocation)
    else {
      assertEq(_allocationsReturned.length, 1);
      assertEq(address(_allocationsReturned[0].delegate), address(delegate));
      assertEq(_allocationsReturned[0].amount, 1 ether);

      assertEq(_weightReturned, 0);

      // Check the mutexes
      assertEq(delegate.ForTest_mutexCommon(), _tokenCount);
      assertEq(delegate.ForTest_mutexReservedRate(), payParams.reservedRate);
      assertEq(delegate.ForTest_mutexTwapQuote(), _swapOutCount);
    }

    // Same memo in any case
    assertEq(_memoReturned, payParams.memo);

    
  }

  /**
   * @notice Test payParams revert if wrong caller
   */
  function test_payParams_revertIfWrongCaller(address _notTerminalStore) public {
    vm.assume(_notTerminalStore != address(terminalStore));

    vm.expectRevert(abi.encodeWithSelector(JBXBuybackDelegate.JuiceBuyback_Unauthorized.selector));

    vm.prank(_notTerminalStore);
    delegate.payParams(payParams);
  }

  /**
   * @notice Test didPay with 1 mutex and token received from swapping
   */
  function test_didPay_oneMutex(uint256 _tokenCount, uint256 _twapQuote) public {
    _tokenCount = bound(_tokenCount, 1, type(uint120).max);
    _twapQuote = bound(_twapQuote, 1, type(uint120).max);

    uint256 _mutex = _tokenCount | _twapQuote << 120 | payParams.reservedRate << 240;

    // Set as one mutex, the other are uninit, at 1
    delegate.ForTest_setMutexes(_mutex, 1, 1);

    // mock the swap call
    vm.mockCall(
      address(pool),
      abi.encodeCall(pool.swap,
        (
          address(delegate),
          address(projectToken) < address(weth),
          int256(1 ether),
          address(projectToken) < address(weth) ? TickMath.MAX_SQRT_RATIO - 1 : TickMath.MIN_SQRT_RATIO + 1,
          abi.encode(_twapQuote)
        )),
      abi.encode(1, 1)
    );

    // mock the transfer call
    vm.mockCall(address(projectToken), abi.encodeCall(projectToken.transfer, (address(jbxTerminal), _tokenCount)), abi.encode(true));


    // mock call to terminal controller of

    // mock calls to mint and burn tokens of

    // expect event

    vm.prank(address(jbxTerminal));
    delegate.didPay(didPayData);
  }
  
  /**
   * @notice Test didPay with 3 mutexes
   */

  /**
   * @notice Test didPay with swap reverting
   */

  /**
   * @notice Test didPay revert if wrong caller
   */

  /**
   * @notice Test uniswapCallback 
   */

  /**
   * @notice Test uniswapCallback revert if wrong caller
   */
   
  /**
   * @notice Test uniswapCallback revert if max slippage
   */

  /**
   * @notice Test sweep 
   */
  
  /**
   * @notice Test sweep revert if transfer fails
   */
}

contract ForTest_JBXBuybackDelegate is JBXBuybackDelegate {
  constructor(
    IERC20 _projectToken,
    IWETH9 _weth,
    IUniswapV3Pool _pool,
    uint32 _secondsAgo,
    uint256 _twapDelta,
    IJBPayoutRedemptionPaymentTerminal3_1 _jbxTerminal,
    IJBProjects _projects,
    IJBOperatorStore _operatorStore
  ) JBXBuybackDelegate(
    _projectToken,
    _weth,
    _pool,
    _secondsAgo,
    _twapDelta,
    _jbxTerminal,
    _projects,
    _operatorStore
  ) {}
  
  function ForTest_mutexCommon() external view returns (uint256) {
    return mutexCommon;
  }

  function ForTest_mutexReservedRate() external view returns (uint256) {
    return mutexReservedRate;
  }

  function ForTest_mutexTwapQuote() external view returns (uint256) {
    return mutexTwapQuote;
  }

  function ForTest_setMutexes(uint256 _mutexCommon, uint256 _mutexReservedRate, uint256 _mutexSwap) external {
    mutexCommon = _mutexCommon;
    mutexReservedRate = _mutexReservedRate;
    mutexTwapQuote = _mutexSwap;
  }

  function ForTest_getQuote(uint256 _amountIn) external view returns (uint256 _amountOut) {
    return _getQuote(_amountIn);
  }
}