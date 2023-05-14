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

import '../JBXBuybackDelegate.sol';
import '../mock/MockAllocator.sol';

contract TestUnitJBXBuybackDelegate is TestBaseWorkflowV3 {
  using JBFundingCycleMetadataResolver for JBFundingCycle;
  JBController controller;
  JBProjectMetadata _projectMetadata;
  JBFundingCycleData _data;
  JBFundingCycleData _dataReconfiguration;
  JBFundingCycleData _dataWithoutBallot;
  JBFundingCycleMetadata _metadata;
  JBFundAccessConstraints[] _fundAccessConstraints; // Default empty
  IJBPaymentTerminal[] _terminals; // Default empty
  uint256 _projectId;

  uint256 reservedRate = 4500;
  uint256 weight = 10**18;
  JBXBuybackDelegate _delegate;

  IWETH9 private constant weth = IWETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
  IJBToken private constant jbx = IJBToken(0x3abF2A4f8452cCC2CF7b4C1e4663147600646f66);

  IUniswapV3Pool private constant pool = IUniswapV3Pool(0x48598Ff1Cee7b4d31f8f9050C2bbAE98e17E6b17);

  function setUp() public override {
    evm.label(address(pool), 'uniswapPool');
    evm.label(address(weth), '$WETH');
    evm.label(address(jbx), '$JBX');

    evm.etch(address(pool), '0x69');
    evm.etch(address(weth), '0x69');
    evm.etch(address(jbx), '0x69');

    super.setUp();

    controller = jbController();

    _delegate = new JBXBuybackDelegate(IERC20(address(jbx)), IERC20(address(weth)), pool, IJBPayoutRedemptionPaymentTerminal3_1(address(jbETHPaymentTerminal())), weth);

    _projectMetadata = JBProjectMetadata({content: 'myIPFSHash', domain: 1});

    _data = JBFundingCycleData({
      duration: 6 days,
      weight: weight,
      discountRate: 0,
      ballot: IJBFundingCycleBallot(address(0))
    });

    _metadata = JBFundingCycleMetadata({
      global: JBGlobalFundingCycleMetadata({allowSetTerminals: false, allowSetController: false, pauseTransfers: false}),
      reservedRate: reservedRate,
      redemptionRate: 5000,
      ballotRedemptionRate: 0,
      pausePay: false,
      pauseDistributions: false,
      pauseRedeem: false,
      pauseBurn: false,
      allowMinting: true,
      preferClaimedTokenOverride: false,
      allowTerminalMigration: false,
      allowControllerMigration: false,
      holdFees: false,
      useTotalOverflowForRedemptions: false,
      useDataSourceForPay: true,
      useDataSourceForRedeem: false,
      dataSource: address(_delegate),
      metadata: 0
    });

    _fundAccessConstraints.push(
      JBFundAccessConstraints({
        terminal: jbETHPaymentTerminal(),
        token: jbLibraries().ETHToken(),
        distributionLimit: 2 ether,
        overflowAllowance: type(uint232).max,
        distributionLimitCurrency: 1, // Currency = ETH
        overflowAllowanceCurrency: 1
      })
    );

    _terminals = [jbETHPaymentTerminal()];

    JBGroupedSplits[] memory _groupedSplits = new JBGroupedSplits[](1); // Default empty

    _projectId = controller.launchProjectFor(
      multisig(),
      _projectMetadata,
      _data,
      _metadata,
      0, // Start asap
      _groupedSplits,
      _fundAccessConstraints,
      _terminals,
      ''
    );
  }

  // If the quote amount is higher than the token that would be recevied after minting or a swap the buy back delegate isn't used
  function testDatasourceDelegateWhenQuoteIsHigherThanTokenCount() public {
    uint256 payAmountInWei = 2 ether;

    _metadata = JBFundingCycleMetadata({
      global: JBGlobalFundingCycleMetadata({allowSetTerminals: false, allowSetController: false, pauseTransfers: false}),
      reservedRate: reservedRate,
      redemptionRate: 5000,
      ballotRedemptionRate: 0,
      pausePay: false,
      pauseDistributions: false,
      pauseRedeem: false,
      pauseBurn: false,
      allowMinting: true,
      preferClaimedTokenOverride: false,
      allowTerminalMigration: false,
      allowControllerMigration: false,
      holdFees: false,
      useTotalOverflowForRedemptions: false,
      useDataSourceForPay: true,
      useDataSourceForRedeem: false,
      dataSource: address(_delegate),
      metadata: 0
    });

    _terminals = [jbETHPaymentTerminal()];

    JBGroupedSplits[] memory _groupedSplits = new JBGroupedSplits[](1); // Default empty

    _projectId = controller.launchProjectFor(
      multisig(),
      _projectMetadata,
      _data,
      _metadata,
      0, // Start asap
      _groupedSplits,
      _fundAccessConstraints,
      _terminals,
      ''
    );
    
    // setting the quote in metadata
    bytes memory metadata = abi.encode(new bytes(0), new bytes(0), 3 ether, 10000);
    
    jbETHPaymentTerminal().pay{value: payAmountInWei}(
      _projectId,
      payAmountInWei,
      address(0),
      beneficiary(),
      /* _minReturnedTokens */
      1,
      /* _preferClaimedTokens */
      false,
      /* _memo */
      'Take my money!',
      /* _delegateMetadata */
      metadata
    );

    uint256 totalMinted = PRBMath.mulDiv(payAmountInWei, weight, 10**18);
    uint256 amountBeneficiary = (totalMinted * (JBConstants.MAX_RESERVED_RATE - reservedRate)) /
      JBConstants.MAX_RESERVED_RATE;
    uint256 amountReserved = totalMinted - amountBeneficiary;

    assertEq(jbTokenStore().balanceOf(beneficiary(), _projectId), amountBeneficiary);
    assertEq(controller.reservedTokenBalanceOf(_projectId, reservedRate), amountReserved);
  }

  // If claimed token flag is not true then make sure the delegate mints the tokens & the balance distribution is correct
  function testDatasourceDelegateMintIfPreferenceIsNotToClaimTokens() public {
    uint256 payAmountInWei = 10 ether;

    // setting the quote in metadata
    bytes memory metadata = abi.encode(new bytes(0), new bytes(0), 1 ether, 10000);

    jbETHPaymentTerminal().pay{value: payAmountInWei}(
      _projectId,
      payAmountInWei,
      address(0),
      beneficiary(),
      /* _minReturnedTokens */
      0, // Cannot be used in this setting
      /* _preferClaimedTokens */
      false,
      /* _memo */
      'Take my money!',
      /* _delegateMetadata */
      metadata
    );

    uint256 totalMinted = PRBMath.mulDiv(payAmountInWei, weight, 10**18);
    uint256 amountBeneficiary = PRBMath.mulDiv(
        totalMinted,
        JBConstants.MAX_RESERVED_RATE - reservedRate,
        JBConstants.MAX_RESERVED_RATE
      );

    uint256 amountReserved = totalMinted - amountBeneficiary;

    assertEq(jbTokenStore().balanceOf(beneficiary(), _projectId), amountBeneficiary);
    assertEq(controller.reservedTokenBalanceOf(_projectId, reservedRate), amountReserved);
    assertEq(jbPaymentTerminalStore().balanceOf(jbETHPaymentTerminal(), _projectId), payAmountInWei);
  }

  // if claimed token flag is true then we go for the swap route
  function testDatasourceDelegateSwapIfPreferenceIsToClaimTokens() public {
    uint256 payAmountInWei = 1 ether;
    uint256 quoteOnUniswap = weight + 1;

    // Mock the swap returned value, which is the amount of token transfered (negative = exact amount)
    evm.mockCall(
      address(pool),
      abi.encodeWithSelector(IUniswapV3PoolActions.swap.selector),
      abi.encode(-int256(quoteOnUniswap), 0)
    );

    jbETHPaymentTerminal().addToBalanceOf{value: payAmountInWei}(
      _projectId,
      payAmountInWei,
      jbLibraries().ETHToken(),
      '',
      bytes('')
    );

    // Trick the balance post-swap
    evm.prank(multisig());

    jbController().mintTokensOf(_projectId, quoteOnUniswap, address(_delegate), '', false, false);

    // setting the quote in metadata
    bytes memory metadata = abi.encode(new bytes(0), new bytes(0), quoteOnUniswap, 10000);

    // Mock the jbx transfer to the beneficiary - same logic as in delegate to avoid rounding errors
    uint256 reservedAmount = PRBMath.mulDiv(
      quoteOnUniswap,
      reservedRate,
      JBConstants.MAX_RESERVED_RATE
    );

    uint256 nonReservedAmount = quoteOnUniswap - reservedAmount;

    evm.mockCall(
      address(jbx),
      abi.encodeWithSelector(
        IERC20.transfer.selector,
        beneficiary(),
        nonReservedAmount
      ),
      abi.encode(true)
    );

    jbETHPaymentTerminal().pay{value: payAmountInWei}(
      _projectId,
      payAmountInWei,
      address(0),
      beneficiary(),
      /* _minReturnedTokens */
      0, // Cannot be used in this setting
      /* _preferClaimedTokens */
      true,
      /* _memo */
      'Take my money!',
      /* _delegateMetadata */
      metadata
    );

    assertEq(
      controller.reservedTokenBalanceOf(_projectId, reservedRate),
      reservedAmount // Last wei rounding
    );
  }

  function testRevertIfSlippageIsTooMuchWhenSwapping() public {
    // construct metadata
    bytes memory metadata = abi.encode(JBTokens.ETH, 100 ether);

    evm.prank(address(pool));
    evm.expectRevert();
    _delegate.uniswapV3SwapCallback(1 ether, 1 ether, metadata);
  }

  function testWhenDelegateCallIsMadeFromAllocator() public {
    JBSplitsStore _jbSplitsStore = jbSplitsStore();

    JBGroupedSplits[] memory _groupedSplits = new JBGroupedSplits[](1); // Default empty

    // deploy new mock project
    uint256 _mockProjectId = controller.launchProjectFor(
      multisig(),
      _projectMetadata,
      _data,
      _metadata,
      0, // Start asap
      _groupedSplits,
      _fundAccessConstraints,
      _terminals,
      ''
    );
    // deploy the bad allocator with the delegate call to buyback delegate
    MockAllocator _mockAllocator = new MockAllocator(_delegate);

    // setting splits
    JBSplit[] memory _splits = new JBSplit[](1);
    _splits[0] = JBSplit({
        preferClaimed: false,
        preferAddToBalance: true,
        projectId: _mockProjectId,
        beneficiary: payable(beneficiary()),
        lockedUntil: 0,
        allocator: _mockAllocator,
        percent:  JBConstants.SPLITS_TOTAL_PERCENT
    });
   
    _groupedSplits[0] = JBGroupedSplits({
         group: 1,
         splits: _splits
    });

    (JBFundingCycle memory _currentFundingCycle, ) = controller.currentFundingCycleOf(_projectId);

    evm.prank(multisig());
    _jbSplitsStore.set(_projectId, _currentFundingCycle.configuration,  _groupedSplits);

    uint256 payAmountInWei = 10 ether;

    // setting the quote in metadata
    bytes memory metadata = abi.encode(new bytes(0), new bytes(0), 1 ether, 10000);

    jbETHPaymentTerminal().pay{value: payAmountInWei}(
      _projectId,
      payAmountInWei,
      address(0),
      beneficiary(),
      /* _minReturnedTokens */
      0, // Cannot be used in this setting
      /* _preferClaimedTokens */
      false,
      /* _memo */
      'Take my money!',
      /* _delegateMetadata */
      metadata
    );

    // distribute funds so we try and use the bad allocator to make a delegate call
    evm.prank(multisig());
    evm.expectRevert();
    jbETHPaymentTerminal().distributePayoutsOf(
      _projectId,
      1 ether,
      1, // Currency
      address(0), //token (unused)
      0, // Min wei out
      'allocation' // Memo
    );
   }
}