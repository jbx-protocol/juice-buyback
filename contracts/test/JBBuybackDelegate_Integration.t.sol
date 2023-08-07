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

import '../JBBuybackDelegate.sol';
import '../mock/MockAllocator.sol';

/**
 * @notice Integration tests for the JBBuybackDelegate contract.
 *
 */
contract TestJBBuybackDelegate_Integration is TestBaseWorkflowV3 {
  using JBFundingCycleMetadataResolver for JBFundingCycle;

  event Mint(
    address indexed holder,
    uint256 indexed projectId,
    uint256 amount,
    bool tokensWereClaimed,
    bool preferClaimedTokens,
    address caller
  );

  JBProjectMetadata _projectMetadata;
  JBFundingCycleData _data;
  JBFundingCycleData _dataReconfiguration;
  JBFundingCycleData _dataWithoutBallot;
  JBFundingCycleMetadata _metadata;
  JBFundAccessConstraints[] _fundAccessConstraints; // Default empty
  IJBPaymentTerminal[] _terminals; // Default empty

  uint256 _projectId;
  uint256 reservedRate = 4500;
  uint256 weight = 10 ** 18; // Minting 1 token per eth

  uint32 cardinality = 1000;

  uint256 twapDelta = 500;

  JBBuybackDelegate _delegate;

  // Use the L1 UniswapV3Pool jbx/eth 1% fee for create2 magic
  IUniswapV3Pool pool = IUniswapV3Pool(0x48598Ff1Cee7b4d31f8f9050C2bbAE98e17E6b17);
  IJBToken jbx = IJBToken(0x3abF2A4f8452cCC2CF7b4C1e4663147600646f66);
  IWETH9 weth = IWETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
  address _uniswapFactory = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
  uint24 fee = 10000;

  /**
   * @notice Set up a new JBX project and use the buyback delegate as the datasource
   */
  function setUp() public override {
    // label
    vm.label(address(pool), 'uniswapPool');
    vm.label(address(_uniswapFactory), 'uniswapFactory');
    vm.label(address(weth), '$WETH');
    vm.label(address(jbx), '$JBX');

    // mock
    vm.etch(address(pool), '0x69');
    vm.etch(address(weth), '0x69');
    vm.etch(address(jbx), '0x69');

    // super is the Jbx V3 fixture
    super.setUp();

    // Deploy the delegate
    _delegate = new JBBuybackDelegate(
      IERC20(address(jbx)),
      weth,
      _uniswapFactory,
      fee,
      cardinality,
      twapDelta,
      IJBDirectory(address(_jbDirectory)),
      _jbController,
      bytes4(hex'69')
    );

    _projectMetadata = JBProjectMetadata({content: 'myIPFSHash', domain: 1});

    _data = JBFundingCycleData({
      duration: 6 days,
      weight: weight,
      discountRate: 0,
      ballot: IJBFundingCycleBallot(address(0))
    });

    _metadata = JBFundingCycleMetadata({
      global: JBGlobalFundingCycleMetadata({
        allowSetTerminals: false,
        allowSetController: false,
        pauseTransfers: false
      }),
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
        terminal: _jbETHPaymentTerminal,
        token: jbLibraries().ETHToken(),
        distributionLimit: 2 ether,
        overflowAllowance: type(uint232).max,
        distributionLimitCurrency: 1, // Currency = ETH
        overflowAllowanceCurrency: 1
      })
    );

    _terminals = [_jbETHPaymentTerminal];

    JBGroupedSplits[] memory _groupedSplits = new JBGroupedSplits[](1); // Default empty

    _projectId = _jbController.launchProjectFor(
      _multisig,
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

  /**
   * @notice  If the quote amount is lower than the token that would be received after minting, the buyback delegate isn't used at all
   */
  function testDatasourceDelegateWhenQuoteIsLowerThanTokenCount(uint256 _quote) public {
    // Do not use a quote of 0, as it would then fetch a twap
    _quote = bound(_quote, 1, weight);

    uint256 payAmountInWei = 2 ether;

    // setting the quote in metadata, bigger than the weight
    bytes[] memory _data = new bytes[](1);
    _data[0] = abi.encode(_quote, 500);

    // Pass the delegate id
    bytes4[] memory _ids = new bytes4[](1);
    _ids[0] = bytes4(hex'69');

    // Generate the metadata
    bytes memory _metadata = _delegate.createMetadata(_ids, _data);

    // Compute the project token which should have been minted (for the beneficiary or the reserve)
    uint256 totalMinted = PRBMath.mulDiv(payAmountInWei, weight, 10 ** 18);
    uint256 amountBeneficiary = (totalMinted * (JBConstants.MAX_RESERVED_RATE - reservedRate)) /
      JBConstants.MAX_RESERVED_RATE;
    uint256 amountReserved = totalMinted - amountBeneficiary;

    // This shouldn't mint via the delegate
    vm.expectEmit(true, true, true, true);
    emit Mint({
      holder: _beneficiary,
      projectId: _projectId,
      amount: amountBeneficiary,
      tokensWereClaimed: false,
      preferClaimedTokens: true,
      caller: address(_jbController)
    });

    _jbETHPaymentTerminal.pay{value: payAmountInWei}(
      _projectId,
      payAmountInWei,
      address(0),
      _beneficiary,
      /* _minReturnedTokens */
      0,
      /* _preferClaimedTokens */
      true,
      /* _memo */
      'Take my money!',
      /* _delegateMetadata */
      _metadata
    );

    // Check: correct beneficiary balance?
    assertEq(_jbTokenStore.balanceOf(_beneficiary, _projectId), amountBeneficiary);

    // Check: correct reserve?
    assertEq(_jbController.reservedTokenBalanceOf(_projectId), amountReserved);
  }

  /**
   * @notice If claimed token flag is not true then make sure the delegate mints the tokens & the balance distribution is correct
   */
  function testDatasourceDelegateMintIfPreferenceIsNotToClaimTokens() public {
    uint256 payAmountInWei = 10 ether;

    // setting the quote in metadata
    bytes[] memory _data = new bytes[](1);
    _data[0] = abi.encode(1 ether, 10000);

    // Pass the delegate id
    bytes4[] memory _ids = new bytes4[](1);
    _ids[0] = bytes4(hex'69');

    // Generate the metadata
    bytes memory _metadata = _delegate.createMetadata(_ids, _data);

    uint256 totalMinted = PRBMath.mulDiv(payAmountInWei, weight, 10 ** 18);
    uint256 amountBeneficiary = PRBMath.mulDiv(
      totalMinted,
      JBConstants.MAX_RESERVED_RATE - reservedRate,
      JBConstants.MAX_RESERVED_RATE
    );

    uint256 amountReserved = totalMinted - amountBeneficiary;

    // This shouldn't mint via the delegate
    vm.expectEmit(true, true, true, true);
    emit Mint({
      holder: _beneficiary,
      projectId: _projectId,
      amount: amountBeneficiary,
      tokensWereClaimed: false,
      preferClaimedTokens: false,
      caller: address(_jbController)
    });

    _jbETHPaymentTerminal.pay{value: payAmountInWei}(
      _projectId,
      payAmountInWei,
      address(0),
      _beneficiary,
      /* _minReturnedTokens */
      0, // Cannot be used in this setting
      /* _preferClaimedTokens */
      false,
      /* _memo */
      'Take my money!',
      /* _delegateMetadata */
      _metadata
    );

    assertEq(_jbTokenStore.balanceOf(_beneficiary, _projectId), amountBeneficiary);
    assertEq(_jbController.reservedTokenBalanceOf(_projectId), amountReserved);
    assertEq(_jbPaymentTerminalStore.balanceOf(_jbETHPaymentTerminal, _projectId), payAmountInWei);
  }

  /**
   * @notice if claimed token flag is true and the quote is greather than the weight, we go for the swap path
   */
  function testDatasourceDelegateSwapIfPreferenceIsToClaimTokens() public {
    uint256 payAmountInWei = 1 ether;
    uint256 quoteOnUniswap = (weight * 106) / 100; // Take slippage into account

    // Trick the delegate balance post-swap (avoid callback revert on slippage)
    vm.prank(_multisig);
    _jbController.mintTokensOf(_projectId, quoteOnUniswap, address(_delegate), '', false, false);

    // setting the quote in metadata
    bytes[] memory _data = new bytes[](1);
    _data[0] = abi.encode(quoteOnUniswap, 500);

    // Pass the delegate id
    bytes4[] memory _ids = new bytes4[](1);
    _ids[0] = bytes4(hex'69');

    // Generate the metadata
    bytes memory _metadata = _delegate.createMetadata(_ids, _data);

    // Mock the jbx transfer to the beneficiary - same logic as in delegate to avoid rounding errors
    uint256 reservedAmount = PRBMath.mulDiv(
      quoteOnUniswap,
      reservedRate,
      JBConstants.MAX_RESERVED_RATE
    );

    uint256 nonReservedAmount = quoteOnUniswap - reservedAmount;

    // mock the burn call
    vm.mockCall(
      address(_jbController),
      abi.encodeCall(
        _jbController.burnTokensOf,
        (address(_delegate), _projectId, quoteOnUniswap, '', true)
      ),
      abi.encode(true)
    );

    uint256 _beneficiaryBalanceBefore = _jbTokenStore.balanceOf(_beneficiary, _projectId);

    // Mock the swap returned value, which is the amount of token transfered (negative = exact amount)
    vm.mockCall(
      address(pool),
      abi.encodeWithSelector(IUniswapV3PoolActions.swap.selector),
      abi.encode(-int256(quoteOnUniswap), 0)
    );

    // Check: swap triggered?
    vm.expectCall(address(pool), abi.encodeWithSelector(IUniswapV3PoolActions.swap.selector));

    _jbETHPaymentTerminal.pay{value: payAmountInWei}(
      _projectId,
      payAmountInWei,
      address(0),
      _beneficiary,
      /* _minReturnedTokens */
      0,
      /* _preferClaimedTokens */
      true,
      /* _memo */
      'Take my money!',
      /* _delegateMetadata */
      _metadata
    );

    assertEq(
      _jbTokenStore.balanceOf(_beneficiary, _projectId),
      _beneficiaryBalanceBefore + nonReservedAmount
    );

    // Check: correct reserve balance?
    assertEq(_jbController.reservedTokenBalanceOf(_projectId), reservedAmount);
  }

  /**
   * @notice Test the uniswap callback reverting when max slippage is hit
   *
   * @dev    This would mean the _mint is then called
   */
  function testRevertIfSlippageIsTooMuchWhenSwapping() public {
    // construct metadata, minimum amount received is 100
    bytes memory metadata = abi.encode(100 ether);

    vm.prank(address(pool));
    vm.expectRevert(abi.encodeWithSignature('JuiceBuyback_MaximumSlippage()'));

    // callback giving 1 instead
    _delegate.uniswapV3SwapCallback(-1 ether, 1 ether, metadata);
  }
}
