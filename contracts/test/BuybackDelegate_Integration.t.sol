// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import "../interfaces/external/IWETH9.sol";
import "./helpers/TestBaseWorkflowV3.sol";

import "@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBController.sol";
import "@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBFundingCycleStore.sol";
import "@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBFundingCycleBallot.sol";
import "@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBFundingCycleDataSource.sol";
import "@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBOperatable.sol";
import "@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBPayDelegate.sol";
import "@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBRedemptionDelegate.sol";
import "@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBPayoutRedemptionPaymentTerminal.sol";
import "@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBSingleTokenPaymentTerminalStore.sol";
import "@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBToken.sol";
import "@jbx-protocol/juice-contracts-v3/contracts/libraries/JBConstants.sol";
import "@jbx-protocol/juice-contracts-v3/contracts/libraries/JBCurrencies.sol";
import "@jbx-protocol/juice-contracts-v3/contracts/libraries/JBFundingCycleMetadataResolver.sol";
import "@jbx-protocol/juice-contracts-v3/contracts/libraries/JBOperations.sol";
import "@jbx-protocol/juice-contracts-v3/contracts/libraries/JBTokens.sol";
import "@jbx-protocol/juice-contracts-v3/contracts/structs/JBFundingCycle.sol";

import "@paulrberg/contracts/math/PRBMath.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";

import "../JBBuybackDelegate.sol";
import "../mock/MockAllocator.sol";

/**
 * @notice Integration tests for the JBBuybackDelegate contract.
 *
 */
contract TestBuybackDelegate_Integration is TestBaseWorkflowV3 {
    using JBFundingCycleMetadataResolver for JBFundingCycle;

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

    // Using fixed addresses to insure token0/token1 consistency
    IWETH9 private constant weth = IWETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IJBToken private constant jbx = IJBToken(0x3abF2A4f8452cCC2CF7b4C1e4663147600646f66);
    IUniswapV3Pool private constant pool = IUniswapV3Pool(address(69420));

    /**
     * @notice Set up a new JBX project and use the buyback delegate as the datasource
     */
    function setUp() public override {
        // label
        vm.label(address(pool), "uniswapPool");
        vm.label(address(weth), "$WETH");
        vm.label(address(jbx), "$JBX");

        // mock
        vm.etch(address(pool), "0x69");
        vm.etch(address(weth), "0x69");
        vm.etch(address(jbx), "0x69");

        // super is the Jbx V3 fixture
        super.setUp();

        // Deploy the delegate
        _delegate =
        new JBBuybackDelegate(IERC20(address(jbx)), weth, pool, cardinality, twapDelta, IJBPayoutRedemptionPaymentTerminal3_1(address(_jbETHPaymentTerminal)), _jbController);

        _projectMetadata = JBProjectMetadata({content: "myIPFSHash", domain: 1});

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
            ""
        );
    }

    /**
     * @notice  If the quote amount is lower than the token that would be received after minting, the buyback delegate isn't used at all
     */
    function testDatasourceDelegateWhenQuoteIsLowerThanTokenCount(uint256 _quote) public {
        _quote = bound(_quote, 0, weight);

        uint256 payAmountInWei = 2 ether;

        // setting the quote in metadata, bigger than the weight
        bytes memory metadata = abi.encode(new bytes(0), new bytes(0), _quote, 500);

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
            "Take my money!",
            /* _delegateMetadata */
            metadata
        );

        // Compute the project token which should have been minted (for the beneficiary or the reserve)
        uint256 totalMinted = PRBMath.mulDiv(payAmountInWei, weight, 10 ** 18);
        uint256 amountBeneficiary =
            (totalMinted * (JBConstants.MAX_RESERVED_RATE - reservedRate)) / JBConstants.MAX_RESERVED_RATE;
        uint256 amountReserved = totalMinted - amountBeneficiary;

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
        bytes memory metadata = abi.encode(new bytes(0), new bytes(0), 1 ether, 10000);

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
            "Take my money!",
            /* _delegateMetadata */
            metadata
        );

        uint256 totalMinted = PRBMath.mulDiv(payAmountInWei, weight, 10 ** 18);
        uint256 amountBeneficiary =
            PRBMath.mulDiv(totalMinted, JBConstants.MAX_RESERVED_RATE - reservedRate, JBConstants.MAX_RESERVED_RATE);

        uint256 amountReserved = totalMinted - amountBeneficiary;

        assertEq(_jbTokenStore.balanceOf(_beneficiary, _projectId), amountBeneficiary);
        assertEq(_jbController.reservedTokenBalanceOf(_projectId), amountReserved);
        assertEq(_jbPaymentTerminalStore.balanceOf(_jbETHPaymentTerminal, _projectId), payAmountInWei);
    }

    /**
     * @notice if claimed token flag is true and the quote is greather than the weight, we go for the swap path
     */
    function testDatasourceDelegateSwapIfPreferenceIsToClaimTokens() public {
        uint256 payAmountInWei = 1 ether;
        uint256 quoteOnUniswap = weight * 106 / 100; // Take slippage into account

        // Trick the delegate balance post-swap (avoid callback revert on slippage)
        vm.prank(_multisig);
        _jbController.mintTokensOf(_projectId, quoteOnUniswap, address(_delegate), "", false, false);

        // setting the quote in metadata
        bytes memory metadata = abi.encode(new bytes(0), new bytes(0), quoteOnUniswap, 500);

        // Mock the jbx transfer to the beneficiary - same logic as in delegate to avoid rounding errors
        uint256 reservedAmount = PRBMath.mulDiv(quoteOnUniswap, reservedRate, JBConstants.MAX_RESERVED_RATE);

        uint256 nonReservedAmount = quoteOnUniswap - reservedAmount;

        // Mock the transfer to the beneficiary
        vm.mockCall(
            address(jbx),
            abi.encodeWithSelector(IERC20.transfer.selector, _beneficiary, nonReservedAmount),
            abi.encode(true)
        );

        // Check: token actually transfered?
        vm.expectCall(address(jbx), abi.encodeWithSelector(IERC20.transfer.selector, _beneficiary, nonReservedAmount));

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
            "Take my money!",
            /* _delegateMetadata */
            metadata
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
        vm.expectRevert(abi.encodeWithSignature("JuiceBuyback_MaximumSlippage()"));

        // callback giving 1 instead
        _delegate.uniswapV3SwapCallback(-1 ether, 1 ether, metadata);
    }
}
