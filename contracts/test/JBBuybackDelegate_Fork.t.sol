// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import "../interfaces/external/IWETH9.sol";
import "./helpers/TestBaseWorkflowV3.sol";

import {JBDelegateMetadataHelper} from "@jbx-protocol/juice-delegate-metadata-lib/src/JBDelegateMetadataHelper.sol";

import "@paulrberg/contracts/math/PRBMath.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";

import "@exhausted-pigeon/uniswap-v3-forge-quoter/src/UniswapV3ForgeQuoter.sol";

import "../JBBuybackDelegate.sol";

import {mulDiv18} from "@prb/math/src/Common.sol";

/**
 * @notice Buyback fork integration tests, using $jbx v3
 */
contract TestJBBuybackDelegate_Fork is Test, UniswapV3ForgeQuoter {
    using JBFundingCycleMetadataResolver for JBFundingCycle;

    event BuybackDelegate_Swap(uint256 indexed projectId, uint256 amountIn, IUniswapV3Pool pool, uint256 amountOut, address caller);
    event Mint(
        address indexed holder,
        uint256 indexed projectId,
        uint256 amount,
        bool tokensWereClaimed,
        bool preferClaimedTokens,
        address caller
    );

    // Constants
    uint256 constant SLIPPAGE_DENOMINATOR = 10000;

    IUniswapV3Factory constant factory = IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);
    IERC20 constant jbx  = IERC20(0x4554CC10898f92D45378b98D6D6c2dD54c687Fb2); // 0 - 69420*10**18
    IWETH9 constant weth = IWETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2); // 1 - 1*10**18

    uint256 constant price = 69420 ether;
    uint32 constant cardinality = 100000;
    uint256 constant twapDelta = 500;
    uint24 constant fee = 10000;
    
    uint256 constant amountPaid = 1 ether;


    // Contracts needed
    IJBFundingCycleStore jbFundingCycleStore;
    IJBDirectory jbDirectory;
    IJBProjects jbProjects;
    IJBSplitsStore jbSplitsStore;
    IJBPayoutRedemptionPaymentTerminal3_1_1 jbEthPaymentTerminal;
    IJBSingleTokenPaymentTerminal terminal;
    IJBSingleTokenPaymentTerminalStore jbTerminalStore;
    IJBController3_1 jbController;
    IJBTokenStore jbTokenStore;
    IJBOperatorStore jbOperatorStore;
    IUniswapV3Pool pool;
    JBDelegateMetadataHelper metadataHelper;

    // Structure needed
    JBProjectMetadata projectMetadata;
    JBFundingCycleData data;
    JBFundingCycleMetadata metadata;
    JBFundAccessConstraints[] fundAccessConstraints;
    IJBPaymentTerminal[] terminals;
    JBGroupedSplits[] groupedSplits;

    // Target contract
    JBBuybackDelegate delegate;
    
    address beneficiary = makeAddr('benefichiary');

    // sqrtPriceX96 = sqrt(1*10**18 << 192 / 69420*10**18) = 300702666377442711115399168 (?)
    uint160 sqrtPriceX96 = 300702666377442711115399168;

    uint256 amountOutQuoted;

    function setUp() public {
        vm.createSelectFork("https://rpc.ankr.com/eth",17962427);

        // Collect the mainnet deployment addresses
        jbDirectory = IJBDirectory(
            stdJson.readAddress(
                vm.readFile("node_modules/@jbx-protocol/juice-contracts-v3/deployments/mainnet/JBDirectory.json"),
                ".address"
            )
        );

        jbEthPaymentTerminal = IJBPayoutRedemptionPaymentTerminal3_1_1(
            stdJson.readAddress(
                vm.readFile(
                    "node_modules/@jbx-protocol/juice-contracts-v3/deployments/mainnet/JBETHPaymentTerminal3_1_1.json"
                ),
                ".address"
            )
        );

        terminal = IJBSingleTokenPaymentTerminal(
            stdJson.readAddress(
                vm.readFile(
                    "node_modules/@jbx-protocol/juice-contracts-v3/deployments/mainnet/JBETHPaymentTerminal3_1_1.json"
                ),
                ".address"
            )
        );
        vm.label(address(jbEthPaymentTerminal), "jbEthPaymentTerminal3_1_1");

        jbController = IJBController3_1(
            stdJson.readAddress(
                vm.readFile("node_modules/@jbx-protocol/juice-contracts-v3/deployments/mainnet/JBController3_1.json"),
                ".address"
            )
        );
        vm.label(address(jbController), "jbController");

        jbTerminalStore = IJBSingleTokenPaymentTerminalStore(0x82129d4109625F94582bDdF6101a8Cd1a27919f5);
        vm.label(address(jbTerminalStore), "jbTerminalStore");

        jbTokenStore = jbController.tokenStore();
        jbFundingCycleStore = jbController.fundingCycleStore();
        jbProjects = jbController.projects();
        jbOperatorStore = IJBOperatable(address(jbTokenStore)).operatorStore();
        jbSplitsStore = jbController.splitsStore();

        delegate = new JBBuybackDelegate({
            _weth: weth,
            _factory: address(factory),
            _directory: IJBDirectory(address(jbDirectory)),
            _controller: jbController,
            _delegateId: bytes4(hex'69')
        });

        // JBX V3 pool wasn't deployed at that block
        pool = IUniswapV3Pool(factory.createPool(address(weth), address(jbx), fee));
        pool.initialize(sqrtPriceX96); // 1 eth <=> 69420 jbx

        address LP = makeAddr('LP');
        vm.startPrank(LP, LP);
        deal(address(weth), LP, 10000000 ether);
        deal(address(jbx), LP, 10000000 ether);

        // create a full range position
        address POSITION_MANAGER = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
        jbx.approve(POSITION_MANAGER, 10000000 ether);
        weth.approve(POSITION_MANAGER, 10000000 ether);

        // mint concentrated position
        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: address(jbx),
            token1: address(weth),
            fee: fee,
            // considering a max valid range
            tickLower: -840000,
            tickUpper: 840000,
            amount0Desired: 10000000 ether,
            amount1Desired: 10000000 ether,
            amount0Min: 0,
            amount1Min: 0,
            recipient: LP,
            deadline: block.timestamp
        });

        INonfungiblePositionManager(POSITION_MANAGER).mint(params);

        vm.stopPrank();

        vm.prank(jbProjects.ownerOf(1));
        delegate.setPoolFor(1, fee, cardinality, twapDelta, address(weth));

        amountOutQuoted = getAmountOut(pool, 1 ether, address(weth));

        metadataHelper = new JBDelegateMetadataHelper();

        vm.label(address(pool), "uniswapPool");
        vm.label(address(factory), "uniswapFactory");
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
        _amountOut -= (_amountOut * _twapDelta) / SLIPPAGE_DENOMINATOR;
    }

    /**
     * @notice If the amount of token returned by minting is greater than by swapping, mint
     *
     * @dev    Should mint for both beneficiary and reserve
     */
    function test_mintIfWeightGreatherThanPrice(uint256 _weight, uint256 _amountIn) public {
        _amountIn = bound(_amountIn, 100, 100 ether);

        uint256 _amountOutQuoted = getAmountOut(pool, _amountIn, address(weth));

        // Reconfigure with a weight bigger than the price implied by the quote
        _weight = bound(_weight, (_amountOutQuoted * 10**18 / _amountIn) + 1, type(uint88).max);

        _reconfigure(1, address(delegate), _weight, 5000);

        uint256 _reservedBalanceBefore = jbController.reservedTokenBalanceOf(1);

        // Build the metadata using the quote at that block
        bytes[] memory _data = new bytes[](1);
        _data[0] = abi.encode(_amountIn, _amountOutQuoted);

        // Pass the delegate id
        bytes4[] memory _ids = new bytes4[](1);
        _ids[0] = bytes4(hex"69");

        // Generate the metadata
        bytes memory _delegateMetadata = metadataHelper.createMetadata(_ids, _data);

        // This shouldn't mint via the delegate
        vm.expectEmit(true, true, true, true);
        emit Mint({
            holder: beneficiary,
            projectId: 1,
            amount: mulDiv18(_weight, _amountIn) / 2, // Half is reserved
            tokensWereClaimed: true,
            preferClaimedTokens: true,
            caller: address(jbController)
        });

        uint256 _balBeforePayment = jbx.balanceOf(beneficiary);

        // Pay the project
        jbEthPaymentTerminal.pay{value: _amountIn}(
            1,
            _amountIn,
            address(0),
            beneficiary,
            /* _minReturnedTokens */
            0,
            /* _preferClaimedTokens */
            true,
            /* _memo */
            "Take my money!",
            /* _delegateMetadata */
            _delegateMetadata
        );

        uint256 _balAfterPayment = jbx.balanceOf(beneficiary);
        uint256 _diff = _balAfterPayment - _balBeforePayment;

        // Check: token received by the beneficiary
        assertEq(_diff, mulDiv18(_weight, _amountIn) / 2);

        // Check: token added to the reserve - 1 wei sensitivity for rounding errors
        assertApproxEqAbs(jbController.reservedTokenBalanceOf(1), _reservedBalanceBefore + mulDiv18(_weight, _amountIn) / 2, 1);
    }

    /**
     * @notice If the amount of token returned by swapping is greater than by minting, swap
     *
     * @dev    Should swap for both beneficiary and reserve (by burning/minting)
     */
    function test_swapIfQuoteBetter(uint256 _weight, uint256 _amountIn, uint256 _reservedRate) public {
        _amountIn = bound(_amountIn, 100, 100 ether);

        uint256 _amountOutQuoted = getAmountOut(pool, _amountIn, address(weth));

        // Reconfigure with a weight smaller than the price implied by the quote
        _weight = bound(_weight, 1, (_amountOutQuoted * 10**18 / _amountIn) - 1);

        _reservedRate = bound(_reservedRate, 0, 10000);

        _reconfigure(1, address(delegate), _weight, _reservedRate);

        uint256 _reservedBalanceBefore = jbController.reservedTokenBalanceOf(1);

        // Build the metadata using the quote at that block
        bytes[] memory _data = new bytes[](1);
        _data[0] = abi.encode(_amountIn, _amountOutQuoted);

        // Pass the delegate id
        bytes4[] memory _ids = new bytes4[](1);
        _ids[0] = bytes4(hex"69");

        // Generate the metadata
        bytes memory _delegateMetadata = metadataHelper.createMetadata(_ids, _data);

        uint256 _balBeforePayment = jbx.balanceOf(beneficiary);

        vm.expectEmit(true, true, true, true);
        emit BuybackDelegate_Swap(1, _amountIn, pool, _amountOutQuoted, address(jbEthPaymentTerminal));

        // Pay the project
        jbEthPaymentTerminal.pay{value: _amountIn}(
            1,
            _amountIn,
            address(0),
            beneficiary,
            /* _minReturnedTokens */
            0,
            /* _preferClaimedTokens */
            true,
            /* _memo */
            "Take my money!",
            /* _delegateMetadata */
            _delegateMetadata
        );

        // Check: token received by the beneficiary
        assertApproxEqAbs(jbx.balanceOf(beneficiary) - _balBeforePayment, _amountOutQuoted - (_amountOutQuoted * _reservedRate / 10000), 1, "wrong balance");

        // Check: token added to the reserve - 1 wei sensitivity for rounding errors
        assertApproxEqAbs(jbController.reservedTokenBalanceOf(1), _reservedBalanceBefore + _amountOutQuoted * _reservedRate / 10000, 1, "wrong reserve");
    }

    /**
     * @notice Use the delegate multiple times to swap, with different quotes
     */
    function test_swapMultiple() public {
        // Reconfigure with a weight of 1 wei, to force swapping
        uint256 _weight = 1;
        _reconfigure(1, address(delegate), _weight, 5000);

        // Build the metadata using the quote at that block
        // Build the metadata using the quote at that block
        bytes[] memory _data = new bytes[](1);
        _data[0] = abi.encode(amountPaid, amountOutQuoted);

        // Pass the delegate id
        bytes4[] memory _ids = new bytes4[](1);
        _ids[0] = bytes4(hex"69");

        // Generate the metadata
        bytes memory _delegateMetadata = metadataHelper.createMetadata(_ids, _data);

        // Pay the project
        jbEthPaymentTerminal.pay{value: amountPaid}(
            1,
            amountPaid,
            address(0),
            beneficiary,
            /* _minReturnedTokens */
            0,
            /* _preferClaimedTokens */
            true,
            /* _memo */
            "Take my money!",
            /* _delegateMetadata */
            _delegateMetadata
        );

        uint256 _balanceBeneficiary = jbx.balanceOf(beneficiary);

        uint256 _reserveBalance = jbController.reservedTokenBalanceOf(1);

        // Update the quote, this is now a different one as we already swapped
        uint256 _previousQuote = amountOutQuoted;
        amountOutQuoted = getAmountOut(pool, 1 ether, address(weth));

        // Sanity check
        assert(_previousQuote != amountOutQuoted);

        // Update the metadata
        _data[0] = abi.encode(amountPaid, amountOutQuoted);

        // Generate the metadata
        _delegateMetadata = metadataHelper.createMetadata(_ids, _data);

        // Pay the project
        jbEthPaymentTerminal.pay{value: amountPaid}(
            1,
            amountPaid,
            address(0),
            beneficiary,
            /* _minReturnedTokens */
            0,
            /* _preferClaimedTokens */
            true,
            /* _memo */
            "Take my money!",
            /* _delegateMetadata */
            _delegateMetadata
        );

        // Check: token received by the beneficiary
        assertEq(jbx.balanceOf(beneficiary), _balanceBeneficiary + amountOutQuoted / 2);

        // Check: token added to the reserve - 1 wei sensitivity for rounding errors
        assertApproxEqAbs(jbController.reservedTokenBalanceOf(1), _reserveBalance + amountOutQuoted / 2, 1);
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
        bytes[] memory _data = new bytes[](1);
        _data[0] = abi.encode(_amountIn, _quote);

        // Pass the delegate id
        bytes4[] memory _ids = new bytes4[](1);
        _ids[0] = bytes4(hex"69");

        // Generate the metadata
        bytes memory _delegateMetadata = metadataHelper.createMetadata(_ids, _data);

        vm.expectEmit(true, true, true, true);
        emit BuybackDelegate_Swap(1, _amountIn, pool, _quote, address(jbEthPaymentTerminal));

        uint256 _balBeforePayment = jbx.balanceOf(beneficiary);

        // Pay the project
        jbEthPaymentTerminal.pay{value: _amountIn}(
            1,
            _amountIn,
            address(0),
            beneficiary,
            /* _minReturnedTokens */
            0,
            /* _preferClaimedTokens */
            true,
            /* _memo */
            "Take my money!",
            /* _delegateMetadata */
            _delegateMetadata
        );

        uint256 _balAfterPayment = jbx.balanceOf(beneficiary);
        uint256 _diff = _balAfterPayment - _balBeforePayment;

        // Check: token received by the beneficiary
        assertEq(_diff, _quote);

        // Check: reserve unchanged
        assertEq(jbController.reservedTokenBalanceOf(1), _reservedBalanceBefore);
    }

    /**
     * @notice If the amount of token returned by swapping is greater than by minting, swap & use quote from uniswap lib rather than a user provided quote
     *
     * @dev    Should swap for both beneficiary and reserve (by burning/minting)
     */
    function test_swapWhenQuoteNotProvidedInMetadata(uint256 _amountIn, uint256 _reservedRate) public {
        _amountIn = bound(_amountIn, 10, 10 ether);
        _reservedRate = bound(_reservedRate, 0, 10000);

        uint256 _weight = 10 ether;

        _reconfigure(1, address(delegate), _weight, _reservedRate);

        uint256 _reservedBalanceBefore = jbController.reservedTokenBalanceOf(1);

        // The twap which is going to be used
        uint256 _twap = _getTwapQuote(_amountIn, cardinality, twapDelta);

        // The actual quote, here for test only
        uint256 _quote = getAmountOut(pool, _amountIn, address(weth));

        // for checking balance difference after payment
        uint256 _balanceBeforePayment = jbx.balanceOf(beneficiary);

        // Pay the project
        jbEthPaymentTerminal.pay{value: _amountIn}(
            1,
            _amountIn,
            address(0),
            beneficiary,
            /* _minReturnedTokens */
            0,
            /* _preferClaimedTokens */
            true,
            /* _memo */
            "Take my money!",
            /* _delegateMetadata */
            new bytes(0)
        );

        uint256 _balanceAfterPayment = jbx.balanceOf(beneficiary);
        uint256 _tokenReceived = _balanceAfterPayment - _balanceBeforePayment;

        uint256 _tokenCount = mulDiv18(_amountIn, _weight);

        // 1 wei sensitivity for rounding errors
        if (_twap > _tokenCount) {
            // Path is picked based on twap, but the token received are the one quoted
            assertApproxEqAbs(_tokenReceived, _quote - (_quote * _reservedRate) / 10000, 1, "wrong swap");
            assertApproxEqAbs(jbController.reservedTokenBalanceOf(1), _reservedBalanceBefore + (_quote * _reservedRate) / 10000, 1, "Reserve");
        } else {
            assertApproxEqAbs(_tokenReceived, _tokenCount - (_tokenCount * _reservedRate) / 10000, 1, "Wrong mint");
            assertApproxEqAbs(jbController.reservedTokenBalanceOf(1), _reservedBalanceBefore + (_tokenCount * _reservedRate) / 10000, 1, "Reserve");
        }
    }

    /**
     * @notice If the amount of token returned by minting is greater than by swapping, we mint outside of the delegate & when there is no user provided quote presemt in metadata
     *
     * @dev    Should mint for both beneficiary and reserve
     */
    function test_swapWhenMintIsPreferredEvenWhenMetadataIsNotPresent(uint256 _amountIn) public {
        _amountIn = bound(_amountIn, 1 ether, 1000 ether);

        uint256 _reservedBalanceBefore = jbController.reservedTokenBalanceOf(1);

        // Reconfigure with a weight of amountOutQuoted + 1
        _reconfigure(1, address(delegate), amountOutQuoted + 1, 0);

        uint256 _balBeforePayment = jbx.balanceOf(beneficiary);

        // Pay the project
        jbEthPaymentTerminal.pay{value: _amountIn}(
            1,
            _amountIn,
            address(0),
            beneficiary,
            /* _minReturnedTokens */
            0,
            /* _preferClaimedTokens */
            true,
            /* _memo */
            "Take my money!",
            /* _delegateMetadata */
            new bytes(0)
        );

        uint256 expectedTokenCount = PRBMath.mulDiv(_amountIn, amountOutQuoted + 1, 10 ** 18);

        uint256 _balAfterPayment = jbx.balanceOf(beneficiary);
        uint256 _diff = _balAfterPayment - _balBeforePayment;

        // Check: token received by the beneficiary
        assertEq(_diff, expectedTokenCount);

        // Check: reserve unchanged
        assertEq(jbController.reservedTokenBalanceOf(1), _reservedBalanceBefore);
    }

    /**
     * @notice If the amount of token returned by swapping is greater than by minting but slippage is too high,
     *         revert if a quote was passed in the pay data
     */
    function test_revertIfSlippageTooHighAndQuote() public {
        uint256 _weight = 50;
        // Reconfigure with a weight smaller than the quote, slippage included
        _reconfigure(1, address(delegate), _weight, 5000);

        // Build the metadata using the quote at that block
        bytes[] memory _data = new bytes[](1);
        _data[0] = abi.encode(
            0,
            69412820131620254304865 + 10 // 10 more than quote at that block
        );

        // Pass the delegate id
        bytes4[] memory _ids = new bytes4[](1);
        _ids[0] = bytes4(hex"69");

        // Generate the metadata
        bytes memory _delegateMetadata = metadataHelper.createMetadata(_ids, _data);

        vm.expectRevert(IJBBuybackDelegate.JuiceBuyback_MaximumSlippage.selector);

        // Pay the project
        jbEthPaymentTerminal.pay{value: 1 ether}(
            1,
            1 ether,
            address(0),
            beneficiary,
            /* _minReturnedTokens */
            0,
            /* _preferClaimedTokens */
            true,
            /* _memo */
            "Take my money!",
            /* _delegateMetadata */
            _delegateMetadata
        );
    }

    function test_mintWithExtraFunds(uint256 _amountIn, uint256 _amountInExtra) public {
        _amountIn = bound(_amountIn, 100, 10 ether);
        _amountInExtra = bound(_amountInExtra, 100, 10 ether);
        
        // Refresh the quote
        amountOutQuoted = getAmountOut(pool, _amountIn, address(weth));

        // Reconfigure with a weight smaller than the quote
        uint256 _weight = amountOutQuoted * 10**18 / _amountIn - 1;
        _reconfigure(1, address(delegate), _weight, 5000);

        uint256 _reservedBalanceBefore = jbController.reservedTokenBalanceOf(1);

        // Build the metadata using the quote at that block
        bytes[] memory _data = new bytes[](1);
        _data[0] = abi.encode(_amountIn, amountOutQuoted);

        // Pass the delegate id
        bytes4[] memory _ids = new bytes4[](1);
        _ids[0] = bytes4(hex"69");

        // Generate the metadata
        bytes memory _delegateMetadata = metadataHelper.createMetadata(_ids, _data);

        uint256 _balBeforePayment = jbx.balanceOf(beneficiary);

        vm.expectEmit(true, true, true, true);
        emit BuybackDelegate_Swap(1, _amountIn, pool, amountOutQuoted, address(jbEthPaymentTerminal));

        // Pay the project
        jbEthPaymentTerminal.pay{value: _amountIn + _amountInExtra}(
            1,
            _amountIn + _amountInExtra,
            address(0),
            beneficiary,
            /* _minReturnedTokens */
            0,
            /* _preferClaimedTokens */
            true,
            /* _memo */
            "Take my money!",
            /* _delegateMetadata */
            _delegateMetadata
        );

        // Check: token received by the beneficiary
        assertApproxEqAbs(jbx.balanceOf(beneficiary) - _balBeforePayment, amountOutQuoted / 2 + mulDiv18(_amountInExtra, _weight) / 2, 10);

        // Check: token added to the reserve
        assertApproxEqAbs(jbController.reservedTokenBalanceOf(1), _reservedBalanceBefore + amountOutQuoted / 2 + mulDiv18(_amountInExtra, _weight) / 2, 10);
    }

    function _reconfigure(uint256 _projectId, address _delegate, uint256 _weight, uint256 _reservedRate) internal {
        address _projectOwner = jbProjects.ownerOf(_projectId);

        JBFundingCycle memory _fundingCycle = jbFundingCycleStore.currentOf(_projectId);
        metadata = _fundingCycle.expandMetadata();

        JBGroupedSplits[] memory _groupedSplits = new JBGroupedSplits[](1);
        _groupedSplits[0] = JBGroupedSplits({
            group: 1,
            splits: jbSplitsStore.splitsOf(
                _projectId,
                _fundingCycle.configuration,
                /*domain*/
                JBSplitsGroups.ETH_PAYOUT /*group*/
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
        vm.warp(block.timestamp + _fundingCycle.duration * 2 + 1);
    }
}
