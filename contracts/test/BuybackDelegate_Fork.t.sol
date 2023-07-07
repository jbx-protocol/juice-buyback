// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import "../interfaces/external/IWETH9.sol";
import "./helpers/TestBaseWorkflowV3.sol";

import "@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBController3_1.sol";
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
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";

import "@exhausted-pigeon/uniswap-v3-forge-quoter/src/UniswapV3ForgeQuoter.sol";

import "../JBBuybackDelegate.sol";
import "../mock/MockAllocator.sol";

import "forge-std/Test.sol";

/**
 * @notice Buyback fork integration tests, using $jbx v3
 */
contract TestBuybackDelegate_Fork is Test, UniswapV3ForgeQuoter {
    using JBFundingCycleMetadataResolver for JBFundingCycle;

    event BuybackDelegate_Swap(uint256 projectId, uint256 amountEth, uint256 amountOut);
    event BuybackDelegate_Mint(uint256 projectId);
    event Mint(
        address indexed holder,
        uint256 indexed projectId,
        uint256 amount,
        bool tokensWereClaimed,
        bool preferClaimedTokens,
        address caller
    );

    // Contracts needed
    IJBFundingCycleStore jbFundingCycleStore;
    IJBProjects jbProjects;
    IJBSplitsStore jbSplitsStore;
    IJBPayoutRedemptionPaymentTerminal3_1 jbEthPaymentTerminal;
    IJBSingleTokenPaymentTerminalStore jbTerminalStore;
    IJBController3_1 jbController;
    IJBTokenStore jbTokenStore;

    IJBOperatorStore jbOperatorStore;

    // Structure needed
    JBProjectMetadata projectMetadata;
    JBFundingCycleData data;
    JBFundingCycleMetadata metadata;
    JBFundAccessConstraints[] fundAccessConstraints;
    IJBPaymentTerminal[] terminals;
    JBGroupedSplits[] groupedSplits;

    JBBuybackDelegate delegate;

    IUniswapV3Pool pool;

    uint256 constant SLIPPAGE_DENOMINATOR = 10000;

    IERC20 jbx = IERC20(0x4554CC10898f92D45378b98D6D6c2dD54c687Fb2); // 0 - 69420*10**18
    IWETH9 weth = IWETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2); // 1 - 1*10**18

    uint256 price = 69420 ether;

    uint32 cardinality = 100000;

    uint256 twapDelta = 500;

    // sqrtPriceX96 = sqrt(1*10**18 << 192 / 69420*10**18) = 300702666377442711115399168 (?)
    uint160 sqrtPriceX96 = 300702666377442711115399168;

    uint256 amountOutForOneEth;

    function setUp() public {
        vm.createSelectFork("https://rpc.ankr.com/eth", 17239357);

        // Collect the mainnet deployment addresses
        jbEthPaymentTerminal = IJBPayoutRedemptionPaymentTerminal3_1(
            stdJson.readAddress(
                vm.readFile(
                    "node_modules/@jbx-protocol/juice-contracts-v3/deployments/mainnet/JBETHPaymentTerminal3_1.json"
                ),
                ".address"
            )
        );
        vm.label(address(jbEthPaymentTerminal), "jbEthPaymentTerminal3_1");

        jbController = IJBController3_1(
            stdJson.readAddress(
                vm.readFile("node_modules/@jbx-protocol/juice-contracts-v3/deployments/mainnet/JBController3_1.json"),
                ".address"
            )
        );
        vm.label(address(jbController), "jbController");

        jbTokenStore = jbController.tokenStore();
        jbFundingCycleStore = jbController.fundingCycleStore();
        jbProjects = jbController.projects();
        jbOperatorStore = IJBOperatable(address(jbTokenStore)).operatorStore();
        jbSplitsStore = jbController.splitsStore();

        pool = IUniswapV3Pool(
            IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984).createPool(address(weth), address(jbx), 100)
        );
        pool.initialize(sqrtPriceX96); // 1 eth <=> 69420 jbx

        vm.startPrank(address(123), address(123));
        deal(address(weth), address(123), 10000000 ether);
        deal(address(jbx), address(123), 10000000 ether);

        // approve:
        address POSITION_MANAGER = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
        jbx.approve(POSITION_MANAGER, 10000000 ether);
        weth.approve(POSITION_MANAGER, 10000000 ether);

        // mint concentrated position
        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: address(jbx),
            token1: address(weth),
            fee: 100,
            tickLower: TickMath.getTickAtSqrtRatio(sqrtPriceX96) - 10 * pool.tickSpacing(),
            tickUpper: TickMath.getTickAtSqrtRatio(sqrtPriceX96) + 10 * pool.tickSpacing(),
            amount0Desired: 10000000 ether,
            amount1Desired: 10000000 ether,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(123),
            deadline: block.timestamp
        });

        INonfungiblePositionManager(POSITION_MANAGER).mint(params);

        vm.stopPrank();

        amountOutForOneEth = getAmountOut(pool, 1 ether, address(weth));

        delegate =
        new JBBuybackDelegate(IERC20(address(jbx)), weth, pool, cardinality, twapDelta, jbEthPaymentTerminal, jbController);

        vm.label(address(pool), "uniswapPool");
        vm.label(address(weth), "$WETH");
        vm.label(address(jbx), "$JBX");
    }

    function _getTwapQuote(uint256 _amountIn, uint32 _secondsAgo, uint256 _twapDelta)
        internal
        view
        returns (uint256 _amountOut)
    {
        // Get the twap tick
        (int24 arithmeticMeanTick,) = OracleLibrary.consult(address(pool), _secondsAgo);

        // Get a quote based on this twap tick
        _amountOut = OracleLibrary.getQuoteAtTick(arithmeticMeanTick, uint128(_amountIn), address(weth), address(jbx));

        // Return the lowest twap accepted
        _amountOut -= _amountOut * _twapDelta / SLIPPAGE_DENOMINATOR;
    }

    /**
     * @notice If the amount of token returned by minting is greater than by swapping, mint
     *
     * @dev    Should mint for both beneficiary and reserve
     */
    function test_mintIfWeightGreatherThanPrice(uint256 _weight) public {
        // Reconfigure with a weight bigger than the quote
        _weight = bound(_weight, amountOutForOneEth + 1, type(uint88).max);
        _reconfigure(1, address(delegate), _weight, 5000);

        uint256 _reservedBalanceBefore = jbController.reservedTokenBalanceOf(1);

        // Build the metadata using the quote at that block
        bytes memory _metadata = abi.encode(
            bytes32(0),
            bytes32(0),
            amountOutForOneEth, //quote
            500 //slippage
        );

        // This shouldn't mint via the delegate
        vm.expectEmit(true, true, true, true);
        emit Mint({
            holder: address(123),
            projectId: 1,
            amount: _weight / 2, // Half is reserved
            tokensWereClaimed: true,
            preferClaimedTokens: true,
            caller: address(jbController)
        });

        // Pay the project
        jbEthPaymentTerminal.pay{value: 1 ether}(
            1,
            1 ether,
            address(0),
            address(123),
            /* _minReturnedTokens */
            0,
            /* _preferClaimedTokens */
            true,
            /* _memo */
            "Take my money!",
            /* _delegateMetadata */
            _metadata
        );

        // Check: token received by the beneficiary
        assertEq(jbx.balanceOf(address(123)), _weight / 2);

        // Check: token added to the reserve - 1 wei sensitivity for rounding errors
        assertApproxEqAbs(jbController.reservedTokenBalanceOf(1), _reservedBalanceBefore + _weight / 2, 1);
    }

    /**
     * @notice If the amount of token returned by swapping is greater than by minting, swap
     *
     * @dev    Should swap for both beneficiary and reserve (by burning/minting)
     */
    function test_swapIfQuoteBetter(uint256 _weight) public {
        // Reconfigure with a weight smaller than the quote, slippage included
        _weight = bound(_weight, 0, amountOutForOneEth - (amountOutForOneEth * 500 / 10000) - 1);
        _reconfigure(1, address(delegate), _weight, 5000);

        uint256 _reservedBalanceBefore = jbController.reservedTokenBalanceOf(1);

        // Build the metadata using the quote at that block
        bytes memory _metadata = abi.encode(
            bytes32(0),
            bytes32(0),
            amountOutForOneEth, //quote
            500 //slippage 500/10000 = 5%
        );

        vm.expectEmit(true, true, true, true);
        emit BuybackDelegate_Swap(1, 1 ether, amountOutForOneEth);

        // Pay the project
        jbEthPaymentTerminal.pay{value: 1 ether}(
            1,
            1 ether,
            address(0),
            address(123),
            /* _minReturnedTokens */
            0,
            /* _preferClaimedTokens */
            true,
            /* _memo */
            "Take my money!",
            /* _delegateMetadata */
            _metadata
        );

        // Check: token received by the beneficiary
        assertEq(jbx.balanceOf(address(123)), amountOutForOneEth / 2);

        // Check: token added to the reserve - 1 wei sensitivity for rounding errors
        assertApproxEqAbs(jbController.reservedTokenBalanceOf(1), _reservedBalanceBefore + amountOutForOneEth / 2, 1);
    }

    /**
     * @notice Use the delegate multiple times to swap, with different quotes
     */
    function test_swapMultiple() public {
        // Reconfigure with a weight of 1 wei, to force swapping
        uint256 _weight = 1;
        _reconfigure(1, address(delegate), _weight, 5000);

        // Build the metadata using the quote at that block
        bytes memory _metadata = abi.encode(
            bytes32(0),
            bytes32(0),
            amountOutForOneEth, //quote
            500 //slippage 500/10000 = 5%
        );

        // Pay the project
        jbEthPaymentTerminal.pay{value: 1 ether}(
            1,
            1 ether,
            address(0),
            address(123),
            /* _minReturnedTokens */
            0,
            /* _preferClaimedTokens */
            true,
            /* _memo */
            "Take my money!",
            /* _delegateMetadata */
            _metadata
        );

        uint256 _balanceBeneficiary = jbx.balanceOf(address(123));

        uint256 _reserveBalance = jbController.reservedTokenBalanceOf(1);

        // Update the quote, this is now a different one as we already swapped
        uint256 _previousQuote = amountOutForOneEth;
        amountOutForOneEth = getAmountOut(pool, 1 ether, address(weth));

        // Sanity check
        assert(_previousQuote != amountOutForOneEth);

        // Update the metadata
        _metadata = abi.encode(
            bytes32(0),
            bytes32(0),
            amountOutForOneEth, //quote
            500 //slippage 500/10000 = 5%
        );

        // Pay the project
        jbEthPaymentTerminal.pay{value: 1 ether}(
            1,
            1 ether,
            address(0),
            address(123),
            /* _minReturnedTokens */
            0,
            /* _preferClaimedTokens */
            true,
            /* _memo */
            "Take my money!",
            /* _delegateMetadata */
            _metadata
        );

        // Check: token received by the beneficiary
        assertEq(jbx.balanceOf(address(123)), _balanceBeneficiary + amountOutForOneEth / 2);

        // Check: token added to the reserve - 1 wei sensitivity for rounding errors
        assertApproxEqAbs(jbController.reservedTokenBalanceOf(1), _reserveBalance + amountOutForOneEth / 2, 1);
    }

    /**
     * @notice If the amount of token returned by swapping is greater than by minting, swap
     *
     * @dev    Should swap for both beneficiary and reserve (by burning/minting)
     */
    function test_swapRandomAmountIn(uint256 _amountIn) public {
        _amountIn = bound(_amountIn, 100, 100 ether);

        uint256 _quote = getAmountOut(pool, _amountIn, address(weth));

        // Reconfigure with a weight of 1
        _reconfigure(1, address(delegate), 1, 0);

        uint256 _reservedBalanceBefore = jbController.reservedTokenBalanceOf(1);

        // Build the metadata using the quote
        bytes memory _metadata = abi.encode(
            bytes32(0),
            bytes32(0),
            _quote, //quote
            500 //slippage 500/10000 = 5%
        );

        vm.expectEmit(true, true, true, true);
        emit BuybackDelegate_Swap(1, _amountIn, _quote);

        // Pay the project
        jbEthPaymentTerminal.pay{value: _amountIn}(
            1,
            _amountIn,
            address(0),
            address(123),
            /* _minReturnedTokens */
            0,
            /* _preferClaimedTokens */
            true,
            /* _memo */
            "Take my money!",
            /* _delegateMetadata */
            _metadata
        );

        // Check: token received by the beneficiary
        assertEq(jbx.balanceOf(address(123)), _quote);

        // Check: reserve unchanged
        assertEq(jbController.reservedTokenBalanceOf(1), _reservedBalanceBefore);
    }

    /**
     * @notice If the amount of token returned by swapping is greater than by minting, swap & use quote from uniswap lib rather than a user provided quote
     *
     * @dev    Should swap for both beneficiary and reserve (by burning/minting)
     */
    function test_swapWhenQuoteNotProvidedInMetadata(uint256 _amountIn) public {
        _amountIn = bound(_amountIn, 100, 100 ether);

        // Reconfigure with a weight of 1
        _reconfigure(1, address(delegate), 1, 0);

        uint256 _reservedBalanceBefore = jbController.reservedTokenBalanceOf(1);

        uint256 _quote = _getTwapQuote(_amountIn, cardinality, twapDelta);

        // Pay the project
        jbEthPaymentTerminal.pay{value: _amountIn}(
            1,
            _amountIn,
            address(0),
            address(123),
            /* _minReturnedTokens */
            0,
            /* _preferClaimedTokens */
            true,
            /* _memo */
            "Take my money!",
            /* _delegateMetadata */
            new bytes(0)
        );

        // Check: token received by the beneficiary
        assertGt(jbx.balanceOf(address(123)), _quote);

        // Check: reserve unchanged
        assertEq(jbController.reservedTokenBalanceOf(1), _reservedBalanceBefore);
    }

    /**
     * @notice If the amount of token returned by swapping is greater than by minting, swap & use quote from uniswap lib rather than a user provided quote & some amount is refunded after the swap
     *
     * @dev    Should swap for both beneficiary and reserve (by burning/minting)
     */
    function test_swapWhenQuoteNotProvidedInMetadataAndWhenRefundHappensAfterTheSwap() public {
        // we need to swap with a large amount to go near the price limit and trigger a refund
        uint256 _largeSwapAmount = 150 ether;
        deal(address(123), _largeSwapAmount);

        // Reconfigure with a weight of 1
        _reconfigure(1, address(delegate), 1, 0);

        uint256 _reservedBalanceBefore = jbController.reservedTokenBalanceOf(1);

        uint256 _quote = _getTwapQuote(_largeSwapAmount, cardinality, twapDelta);

        // Pay the project
        jbEthPaymentTerminal.pay{value: _largeSwapAmount}(
            1,
            _largeSwapAmount,
            address(0),
            address(123),
            /* _minReturnedTokens */
            0,
            /* _preferClaimedTokens */
            true,
            /* _memo */
            "Take my money!",
            /* _delegateMetadata */
            new bytes(0)
        );

        // Check: token received by the beneficiary
        assertGt(jbx.balanceOf(address(123)), _quote);

        // Check: reserve unchanged
        assertEq(jbController.reservedTokenBalanceOf(1), _reservedBalanceBefore);

        // beneficiary sweeping the leftover amount
        uint256 _balanceBeforeSweepingLeftOverFunds = address(123).balance;

        uint256 _currentSweepBalance = delegate.sweepBalance();

        delegate.sweep(address(123));

        uint256 _balanceAftereSweepingLeftOverFunds = address(123).balance;

        assertEq(_balanceAftereSweepingLeftOverFunds - _balanceBeforeSweepingLeftOverFunds, _currentSweepBalance);
    }

    /**
     * @notice If the amount of token returned by swapping is greater than by minting, swap & use quote from uniswap lib when cardinality is increased
     *
     * @dev    Should swap for both beneficiary and reserve (by burning/minting)
     */
    function test_swapWhenCardinalityIsIncreased(uint256 _amountIn) public {
        _amountIn = bound(_amountIn, 100, 100 ether);

        // Reconfigure with a weight of 1
        _reconfigure(1, address(delegate), 1, 0);

        uint256 _reservedBalanceBefore = jbController.reservedTokenBalanceOf(1);

        uint256 _quote = _getTwapQuote(_amountIn, 200000, twapDelta);

        delegate.increaseSecondsAgo(200000);

        // Pay the project
        jbEthPaymentTerminal.pay{value: _amountIn}(
            1,
            _amountIn,
            address(0),
            address(123),
            /* _minReturnedTokens */
            0,
            /* _preferClaimedTokens */
            true,
            /* _memo */
            "Take my money!",
            /* _delegateMetadata */
            new bytes(0)
        );

        // Check: token received by the beneficiary
        assertGt(jbx.balanceOf(address(123)), _quote);

        // Check: reserve unchanged
        assertEq(jbController.reservedTokenBalanceOf(1), _reservedBalanceBefore);
    }

    /**
     * @notice If the amount of token returned by swapping is greater than by minting, swap & use quote from uniswap lib when twapDelta is updated
     *
     * @dev    Should swap for both beneficiary and reserve (by burning/minting)
     */
    function test_swapWhenTwapDeltaIsUpdated(uint256 _amountIn, uint256 _twapDelta) public {
        _amountIn = bound(_amountIn, 100, 100 ether);
        // restricting to avoid slippage errors
        _twapDelta = bound(_twapDelta, 300, 8000);

        // Reconfigure with a weight of 1
        _reconfigure(1, address(delegate), 1, 0);

        uint256 _reservedBalanceBefore = jbController.reservedTokenBalanceOf(1);

        uint256 _quote = _getTwapQuote(_amountIn, cardinality, _twapDelta);

        delegate.setTwapDelta(_twapDelta);

        // Pay the project
        jbEthPaymentTerminal.pay{value: _amountIn}(
            1,
            _amountIn,
            address(0),
            address(123),
            /* _minReturnedTokens */
            0,
            /* _preferClaimedTokens */
            true,
            /* _memo */
            "Take my money!",
            /* _delegateMetadata */
            new bytes(0)
        );

        // Check: token received by the beneficiary
        assertGt(jbx.balanceOf(address(123)), _quote);

        // Check: reserve unchanged
        assertEq(jbController.reservedTokenBalanceOf(1), _reservedBalanceBefore);
    }

    /**
     * @notice If the amount of token returned by minting is greater than by swapping, we mint outside of the delegate & when there is no user provided quote presemt in metadata
     *
     * @dev    Should mint for both beneficiary and reserve
     */
    function test_swapWhenMintIsPreferredEvenWhenMetadataIsNotPresent(uint256 _amountIn) public {
        _amountIn = bound(_amountIn, 1 ether, 1000 ether);

        uint256 _reservedBalanceBefore = jbController.reservedTokenBalanceOf(1);

        // Reconfigure with a weight of amountOutForOneEth + 1
        _reconfigure(1, address(delegate), amountOutForOneEth + 1, 0);

        // Pay the project
        jbEthPaymentTerminal.pay{value: _amountIn}(
            1,
            _amountIn,
            address(0),
            address(123),
            /* _minReturnedTokens */
            0,
            /* _preferClaimedTokens */
            true,
            /* _memo */
            "Take my money!",
            /* _delegateMetadata */
            new bytes(0)
        );

        uint256 expectedTokenCount = PRBMath.mulDiv(_amountIn, amountOutForOneEth + 1, 10 ** 18);

        // Check: token received by the beneficiary
        assertEq(jbx.balanceOf(address(123)), expectedTokenCount);

        // Check: reserve unchanged
        assertEq(jbController.reservedTokenBalanceOf(1), _reservedBalanceBefore);
    }

    /**
     * @notice If the amount of token returned by swapping is greater than by minting but slippage is too high, mint
     */
    function test_mintIfSlippageTooHigh() public {
        uint256 _weight = 50;
        // Reconfigure with a weight smaller than the quote, slippage included
        _reconfigure(1, address(delegate), _weight, 5000);

        uint256 _reservedBalanceBefore = jbController.reservedTokenBalanceOf(1);

        // Build the metadata using the quote at that block
        bytes memory _metadata = abi.encode(
            bytes32(0),
            bytes32(0),
            69412820131620254304865 + 10, // 10 more than quote at that block
            0 //slippage
        );

        // Fall back on delegate minting
        vm.expectEmit(true, true, true, true);
        emit BuybackDelegate_Mint(1);

        // Pay the project
        jbEthPaymentTerminal.pay{value: 1 ether}(
            1,
            1 ether,
            address(0),
            address(123),
            /* _minReturnedTokens */
            0,
            /* _preferClaimedTokens */
            true,
            /* _memo */
            "Take my money!",
            /* _delegateMetadata */
            _metadata
        );

        // Check: token received by the beneficiary
        assertEq(jbx.balanceOf(address(123)), _weight / 2);

        // Check: token added to the reserve - 1 wei sensitivity for rounding errors
        assertApproxEqAbs(jbController.reservedTokenBalanceOf(1), _reservedBalanceBefore + _weight / 2, 1);
    }

    function _reconfigure(uint256 _projectId, address _delegate, uint256 _weight, uint256 _reservedRate) internal {
        address _projectOwner = jbProjects.ownerOf(_projectId);

        JBFundingCycle memory _fundingCycle = jbFundingCycleStore.currentOf(_projectId);
        metadata = _fundingCycle.expandMetadata();

        JBGroupedSplits[] memory _groupedSplits = new JBGroupedSplits[](1);
        _groupedSplits[0] = JBGroupedSplits({
            group: 1,
            splits: jbSplitsStore.splitsOf(
                _projectId, _fundingCycle.configuration, /*domain*/ JBSplitsGroups.ETH_PAYOUT /*group*/
                )
        });

        metadata.useDataSourceForPay = true;
        metadata.dataSource = _delegate;

        metadata.reservedRate = _reservedRate;

        data.weight = _weight;
        data.duration = 14 days;

        // reconfigure
        vm.prank(_projectOwner);
        jbController.reconfigureFundingCyclesOf(
            _projectId, data, metadata, block.timestamp, _groupedSplits, fundAccessConstraints, ""
        );

        // Move to next fc
        vm.warp(block.timestamp + 14 days + 1);
    }
}
