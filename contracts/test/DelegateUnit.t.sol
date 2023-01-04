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

import '../JuiceBuybackDelegate.sol';

contract TestUnitJuiceBuybackDelegate is TestBaseWorkflowV3 {
  using JBFundingCycleMetadataResolver for JBFundingCycle;
  JBController controller;
  JBProjectMetadata _projectMetadata;
  JBFundingCycleData _data;
  JBFundingCycleData _dataReconfiguration;
  JBFundingCycleData _dataWithoutBallot;
  JBFundingCycleMetadata _metadata;
  JBGroupedSplits[] _groupedSplits; // Default empty
  JBFundAccessConstraints[] _fundAccessConstraints; // Default empty
  IJBPaymentTerminal[] _terminals; // Default empty
  uint256 _projectId;

  uint256 reservedRate = 4500;
  uint256 weight = 10**18;
  JuiceBuybackDelegate _delegate;

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

    _delegate = new JuiceBuybackDelegate(IERC20(address(jbx)), weth, pool, jbETHPaymentTerminal(), weth);

    _projectMetadata = JBProjectMetadata({content: 'myIPFSHash', domain: 1});

    _data = JBFundingCycleData({
      duration: 6 days,
      weight: weight,
      discountRate: 0,
      ballot: IJBFundingCycleBallot(address(0))
    });

    _metadata = JBFundingCycleMetadata({
      global: JBGlobalFundingCycleMetadata({allowSetTerminals: false, allowSetController: false, pauseTransfers: false}),
      reservedRate: 10000,
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
        distributionLimit: 0,
        overflowAllowance: type(uint232).max,
        distributionLimitCurrency: 1, // Currency = ETH
        overflowAllowanceCurrency: 1
      })
    );

    _terminals = [jbETHPaymentTerminal()];

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

  // If minting gives a higher amount of project token, mint should be used with proper token distribution to beneficiary and reserved token
  function testDatasourceDelegateMintIfQuoteIsHigher() public {
    uint256 payAmountInWei = 10 ether;

    bytes memory metadata = abi.encode(10, 10);

    _delegate.setReservedRateOf(_projectId, 5000);

    uint256 _nonReservedToken = PRBMath.mulDiv(
      payAmountInWei,
      JBConstants.MAX_RESERVED_RATE - 5000,
      JBConstants.MAX_RESERVED_RATE);

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


    // Delegate is deployed using reservedRate
    uint256 amountBeneficiary = PRBMath.mulDiv(_nonReservedToken, weight, 10**18);
    uint256 amountReserved = ((amountBeneficiary * JBConstants.MAX_RESERVED_RATE) /
      (JBConstants.MAX_RESERVED_RATE - 5000)) - amountBeneficiary;

    assertEq(jbTokenStore().balanceOf(beneficiary(), _projectId), amountBeneficiary);

    assertEq(
      controller.reservedTokenBalanceOf(_projectId, JBConstants.MAX_RESERVED_RATE),
      (amountReserved / 10) * 10 // Last wei rounding
    );
  }
}