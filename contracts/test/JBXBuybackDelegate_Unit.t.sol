// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import "../interfaces/external/IWETH9.sol";
import "./helpers/TestBaseWorkflowV3.sol";

import "@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBController.sol";
import "@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBDirectory.sol";
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

import "forge-std/Test.sol";

import "../JBXBuybackDelegate.sol";

/**
 * @notice Unit tests for the JBXBuybackDelegate contract.
 *
 */
contract TestJBXBuybackDelegate_Units is Test {
    using stdStorage for StdStorage;

    ForTest_JBXBuybackDelegate delegate;

    event JBXBuybackDelegate_Swap(uint256 projectId, uint256 amountEth, uint256 amountOut);
    event JBXBuybackDelegate_Mint(uint256 projectId);
    event JBXBuybackDelegate_SecondsAgoIncrease(uint256 oldSecondsAgo, uint256 newSecondsAgo);
    event JBXBuybackDelegate_TwapDeltaChanged(uint256 oldTwapDelta, uint256 newTwapDelta);
    event JBXBuybackDelegate_PendingSweep(address indexed beneficiary, uint256 amount);

    IERC20 projectToken = IERC20(makeAddr("projectToken"));
    IWETH9 weth = IWETH9(makeAddr("IWETH9"));
    IUniswapV3Pool pool = IUniswapV3Pool(makeAddr("IUniswapV3Pool"));
    IJBPayoutRedemptionPaymentTerminal3_1 jbxTerminal =
        IJBPayoutRedemptionPaymentTerminal3_1(makeAddr("IJBPayoutRedemptionPaymentTerminal3_1"));
    IJBProjects projects = IJBProjects(makeAddr("IJBProjects"));
    IJBOperatorStore operatorStore = IJBOperatorStore(makeAddr("IJBOperatorStore"));
    IJBController controller = IJBController(makeAddr("controller"));
    IJBDirectory directory = IJBDirectory(makeAddr("directory"));

    address terminalStore = makeAddr("terminalStore");

    address dude = makeAddr("dude");

    uint32 secondsAgo = 100;
    uint256 twapDelta = 100;

    JBPayParamsData payParams = JBPayParamsData({
        terminal: jbxTerminal,
        payer: dude,
        amount: JBTokenAmount({token: address(weth), value: 1 ether, decimals: 18, currency: 1}),
        projectId: 69,
        currentFundingCycleConfiguration: 0,
        beneficiary: dude,
        weight: 69,
        reservedRate: 69,
        memo: "myMemo",
        metadata: ""
    });

    JBDidPayData didPayData = JBDidPayData({
        payer: dude,
        projectId: 69,
        currentFundingCycleConfiguration: 0,
        amount: JBTokenAmount({token: address(weth), value: 1 ether, decimals: 18, currency: 1}),
        forwardedAmount: JBTokenAmount({token: address(weth), value: 1 ether, decimals: 18, currency: 1}),
        projectTokenCount: 69,
        beneficiary: dude,
        preferClaimedTokens: true,
        memo: "myMemo",
        metadata: ""
    });

    function setUp() external {
        vm.etch(address(projectToken), "6969");
        vm.etch(address(weth), "6969");
        vm.etch(address(pool), "6969");
        vm.etch(address(jbxTerminal), "6969");
        vm.etch(address(projects), "6969");
        vm.etch(address(operatorStore), "6969");
        vm.etch(address(controller), "6969");
        vm.etch(address(directory), "6969");

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
        bytes memory _metadata = abi.encode("", "", _swapOutCount, _slippage);

        // Set the relevant payParams data
        payParams.weight = _tokenCount;
        payParams.metadata = _metadata;

        // Returned values to catch:
        JBPayDelegateAllocation[] memory _allocationsReturned;
        string memory _memoReturned;
        uint256 _weightReturned;

        // Test: call payParams
        vm.prank(terminalStore);
        (_weightReturned, _memoReturned, _allocationsReturned) = delegate.payParams(payParams);

        // Mint pathway if more token received when minting:
        if (_tokenCount >= _swapOutCount - (_swapOutCount * _slippage / 10000)) {
            // No delegate allocation returned
            assertEq(_allocationsReturned.length, 0);

            // weight unchanged
            assertEq(_weightReturned, _tokenCount);

            // mutex unchanged
            assertEq(delegate.ForTest_mutexCommon(), 1);
            assertEq(delegate.ForTest_mutexReservedRate(), 1);
            assertEq(delegate.ForTest_mutexSwapQuote(), 1);
        }
        // Swap pathway (set the mutexes and return the delegate allocation)
        else {
            assertEq(_allocationsReturned.length, 1);
            assertEq(address(_allocationsReturned[0].delegate), address(delegate));
            assertEq(_allocationsReturned[0].amount, 1 ether);

            assertEq(_weightReturned, 0);

            // Check the mutexes (nothing should be > uint120 -> only one mutex used)
            assertEq(
                delegate.ForTest_mutexCommon(),
                _tokenCount | (_swapOutCount - (_swapOutCount * _slippage / 10000)) << 120
                    | payParams.reservedRate << 240
            );
            assertEq(delegate.ForTest_mutexReservedRate(), 1);
            assertEq(delegate.ForTest_mutexSwapQuote(), 1);
        }

        // Same memo in any case
        assertEq(_memoReturned, payParams.memo);
    }

    /**
     * @notice Test payParams with swap pathway using twap
     *
     * @dev    This bypass testing Uniswap Oracle lib by re-using the internal _getQuote
     */
    function test_payParams_swapWithTwap(uint256 _tokenCount) public {
        _tokenCount = bound(_tokenCount, 1, type(uint120).max);

        // Set the relevant payParams data
        payParams.weight = _tokenCount;
        payParams.metadata = "";

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

        vm.mockCall(
            address(pool),
            abi.encodeCall(pool.observe, (_secondsAgos)),
            abi.encode(_tickCumulatives, _secondPerLiquidity)
        );
        vm.expectCall(address(pool), abi.encodeCall(pool.observe, (_secondsAgos)));

        // Returned values to catch:
        JBPayDelegateAllocation[] memory _allocationsReturned;
        string memory _memoReturned;
        uint256 _weightReturned;

        // Test: call payParams
        vm.prank(terminalStore);
        (_weightReturned, _memoReturned, _allocationsReturned) = delegate.payParams(payParams);

        // Bypass testing uniswap oracle lib
        uint256 _twapAmountOut = delegate.ForTest_getQuote(1 ether);

        // Mint pathway if more token received when minting:
        if (_tokenCount >= _twapAmountOut) {
            // No delegate allocation returned
            assertEq(_allocationsReturned.length, 0);

            // weight unchanged
            assertEq(_weightReturned, _tokenCount);

            // mutex unchanged
            assertEq(delegate.ForTest_mutexCommon(), 1);
            assertEq(delegate.ForTest_mutexReservedRate(), 1);
            assertEq(delegate.ForTest_mutexSwapQuote(), 1);
        }
        // Swap pathway (set the mutexes and return the delegate allocation)
        else {
            assertEq(_allocationsReturned.length, 1);
            assertEq(address(_allocationsReturned[0].delegate), address(delegate));
            assertEq(_allocationsReturned[0].amount, 1 ether);

            assertEq(_weightReturned, 0);

            // Check the mutexes (nothing should be > uint120 -> only one mutex used)
            assertEq(
                delegate.ForTest_mutexCommon(), _tokenCount | _twapAmountOut << 120 | payParams.reservedRate << 240
            );
            assertEq(delegate.ForTest_mutexReservedRate(), 1);
            assertEq(delegate.ForTest_mutexSwapQuote(), 1);
        }

        // Same memo in any case
        assertEq(_memoReturned, payParams.memo);
    }

    /**
     * @notice Test payParams with a twap but locked pool, which should then mint
     */
    function test_payParams_swapWithTwapLockedPool(uint256 _tokenCount) public {
        _tokenCount = bound(_tokenCount, 1, type(uint120).max);

        // Set the relevant payParams data
        payParams.weight = _tokenCount;
        payParams.metadata = "";

        // Mock the pool being unlocked
        vm.mockCall(address(pool), abi.encodeCall(pool.slot0, ()), abi.encode(0, 0, 0, 0, 0, 0, false));
        vm.expectCall(address(pool), abi.encodeCall(pool.slot0, ()));

        // Returned values to catch:
        JBPayDelegateAllocation[] memory _allocationsReturned;
        string memory _memoReturned;
        uint256 _weightReturned;

        // Test: call payParams
        vm.prank(terminalStore);
        (_weightReturned, _memoReturned, _allocationsReturned) = delegate.payParams(payParams);

        // No delegate allocation returned
        assertEq(_allocationsReturned.length, 0);

        // weight unchanged
        assertEq(_weightReturned, _tokenCount);

        // Same memo
        assertEq(_memoReturned, payParams.memo);

        // mutex unchanged
        assertEq(delegate.ForTest_mutexCommon(), 1);
        assertEq(delegate.ForTest_mutexReservedRate(), 1);
        assertEq(delegate.ForTest_mutexSwapQuote(), 1);
    }

    /**
     * @notice Test payParams with a quote or minted amount > uint120
     */
    function test_payParams_swapWithQuoteUsingThreeMutex(uint256 _tokenCount, uint256 _swapOutCount) public {
        _tokenCount = bound(_tokenCount, 1, type(uint256).max);

        _swapOutCount = bound(
            _swapOutCount, _tokenCount > type(uint120).max ? 1 : uint256(type(uint120).max) + 1, type(uint256).max
        );

        // Pass the quote as metadata, no slippage
        bytes memory _metadata = abi.encode("", "", _swapOutCount, 0);

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
        (_weightReturned, _memoReturned, _allocationsReturned) = delegate.payParams(payParams);

        // Mint pathway if more token received when minting:
        if (_tokenCount >= _swapOutCount) {
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
            assertEq(delegate.ForTest_mutexSwapQuote(), _swapOutCount);
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
    function test_didPay_oneMutex(uint256 _tokenCount, uint256 _twapQuote, uint256 _reservedRate) public {
        _tokenCount = bound(_tokenCount, 2, type(uint120).max - 1);
        _twapQuote = bound(_twapQuote, _tokenCount + 1, type(uint120).max);
        _reservedRate = bound(_reservedRate, 0, 10000);

        uint256 _mutex = _tokenCount | _twapQuote << 120 | _reservedRate << 240; // no reserved

        // Set as one mutex, the other are uninit, at 1
        delegate.ForTest_setMutexes(_mutex, 1, 1, 1);

        // The amount the beneficiary should receive
        uint256 _nonReservedToken =
            PRBMath.mulDiv(_twapQuote, JBConstants.MAX_RESERVED_RATE - _reservedRate, JBConstants.MAX_RESERVED_RATE);

        // mock the swap call
        vm.mockCall(
            address(pool),
            abi.encodeCall(
                pool.swap,
                (
                    address(delegate),
                    address(weth) < address(projectToken),
                    int256(1 ether),
                    address(projectToken) < address(weth) ? TickMath.MAX_SQRT_RATIO - 1 : TickMath.MIN_SQRT_RATIO + 1,
                    abi.encode(_twapQuote)
                )
            ),
            abi.encode(-int256(_twapQuote), -int256(_twapQuote))
        );

        // mock the transfer call
        vm.mockCall(
            address(projectToken), abi.encodeCall(projectToken.transfer, (dude, _nonReservedToken)), abi.encode(true)
        );

        // If there are reserved token, mock and expect accordingly
        if (_reservedRate != 0) {
            // mock the call to the directory, to get the controller
            vm.mockCall(address(jbxTerminal), abi.encodeCall(jbxTerminal.directory, ()), abi.encode(address(directory)));
            vm.mockCall(
                address(directory),
                abi.encodeCall(directory.controllerOf, (didPayData.projectId)),
                abi.encode(address(controller))
            );

            // mock the minting call
            vm.mockCall(
                address(controller),
                abi.encodeCall(
                    controller.mintTokensOf,
                    (didPayData.projectId, _twapQuote, address(delegate), didPayData.memo, false, true)
                ),
                abi.encode(true)
            );

            // mock the burn call
            vm.mockCall(
                address(controller),
                abi.encodeCall(controller.burnTokensOf, (address(delegate), didPayData.projectId, _twapQuote, "", true)),
                abi.encode(true)
            );
        }

        // expect event
        vm.expectEmit(true, true, true, true);
        emit JBXBuybackDelegate_Swap(didPayData.projectId, didPayData.amount.value, _twapQuote);

        vm.prank(address(jbxTerminal));
        delegate.didPay(didPayData);
    }

    /**
     * @notice Test didPay with 3 mutexes
     */
    function test_didPay_threeMutex(uint256 _tokenCount, uint256 _twapQuote, uint256 _reservedRate) public {
        _tokenCount = bound(_tokenCount, 2, type(uint256).max - 1);
        _twapQuote = bound(_twapQuote, _tokenCount + 1, type(uint256).max);
        _reservedRate = bound(_reservedRate, 0, 10000);

        // Set the three mutex
        delegate.ForTest_setMutexes(_tokenCount, _twapQuote, _reservedRate, 2);

        // The amount the beneficiary should receive
        uint256 _nonReservedToken =
            PRBMath.mulDiv(_twapQuote, JBConstants.MAX_RESERVED_RATE - _reservedRate, JBConstants.MAX_RESERVED_RATE);

        // mock the swap call
        vm.mockCall(
            address(pool),
            abi.encodeCall(
                pool.swap,
                (
                    address(delegate),
                    address(weth) < address(projectToken),
                    int256(1 ether),
                    address(projectToken) < address(weth) ? TickMath.MAX_SQRT_RATIO - 1 : TickMath.MIN_SQRT_RATIO + 1,
                    abi.encode(_twapQuote)
                )
            ),
            abi.encode(-int256(_twapQuote), -int256(_twapQuote))
        );

        // mock the transfer call
        vm.mockCall(
            address(projectToken), abi.encodeCall(projectToken.transfer, (dude, _nonReservedToken)), abi.encode(true)
        );

        // If there are reserved token, mock and expect accordingly
        if (_reservedRate != 0) {
            // mock the call to the directory, to get the controller
            vm.mockCall(address(jbxTerminal), abi.encodeCall(jbxTerminal.directory, ()), abi.encode(address(directory)));
            vm.mockCall(
                address(directory),
                abi.encodeCall(directory.controllerOf, (didPayData.projectId)),
                abi.encode(address(controller))
            );

            // mock the minting call
            vm.mockCall(
                address(controller),
                abi.encodeCall(
                    controller.mintTokensOf,
                    (didPayData.projectId, _twapQuote, address(delegate), didPayData.memo, false, true)
                ),
                abi.encode(true)
            );

            // mock the burn call
            vm.mockCall(
                address(controller),
                abi.encodeCall(controller.burnTokensOf, (address(delegate), didPayData.projectId, _twapQuote, "", true)),
                abi.encode(true)
            );
        }

        // expect event
        vm.expectEmit(true, true, true, true);
        emit JBXBuybackDelegate_Swap(didPayData.projectId, didPayData.amount.value, _twapQuote);

        vm.prank(address(jbxTerminal));
        delegate.didPay(didPayData);
    }

    /**
     * @notice Test didPay with 1 mutex and token received from swapping
     */
    function test_didPay_keepTrackOfETHToSweep() public {
        uint256 _tokenCount = 10;
        uint256 _twapQuote = 11;
        uint256 _reservedRate = 0;

        uint256 _mutex = _tokenCount | _twapQuote << 120 | _reservedRate << 240; // no reserved

        // Set as one mutex, the other are uninit, at 1
        delegate.ForTest_setMutexes(_mutex, 1, 1, 1);

        // mock the swap call
        vm.mockCall(
            address(pool),
            abi.encodeCall(
                pool.swap,
                (
                    address(delegate),
                    address(weth) < address(projectToken),
                    int256(1 ether),
                    address(projectToken) < address(weth) ? TickMath.MAX_SQRT_RATIO - 1 : TickMath.MIN_SQRT_RATIO + 1,
                    abi.encode(_twapQuote)
                )
            ),
            abi.encode(-int256(_twapQuote), -int256(_twapQuote))
        );

        // Mock the project token transfer
        vm.mockCall(address(projectToken), abi.encodeCall(projectToken.transfer, (dude, _twapQuote)), abi.encode(true));

        // Add some leftover (nothing will be wrapped/transfered as it happens in the callback)
        vm.deal(address(delegate), 10 ether);

        // Add a previous leftover, to test the incremental accounting (ie 5 out of 10 were there)
        stdstore.target(address(delegate)).sig("sweepBalance()").checked_write(5 ether);

        // Out of these 5, 1 was for payer
        stdstore.target(address(delegate)).sig("sweepBalanceOf(address)").with_key(didPayData.payer).checked_write(
            1 ether
        );

        // check: correct event?
        vm.expectEmit(true, true, true, true);
        emit JBXBuybackDelegate_PendingSweep(dude, 5 ether);

        vm.prank(address(jbxTerminal));
        delegate.didPay(didPayData);

        // Check: correct overall sweep balance?
        assertEq(delegate.sweepBalance(), 10 ether);

        // Check: correct dude sweep balance (1 previous plus 5 from now)?
        assertEq(delegate.sweepBalanceOf(dude), 6 ether);
    }
    /**
     * @notice Test didPay with swap reverting, should then mint
     */

    function test_didPay_swapRevert(uint256 _tokenCount, uint256 _twapQuote, uint256 _reservedRate) public {
        _tokenCount = bound(_tokenCount, 2, type(uint120).max - 1);
        _twapQuote = bound(_twapQuote, _tokenCount + 1, type(uint120).max);
        _reservedRate = bound(_reservedRate, 0, 10000);

        uint256 _mutex = _tokenCount | _twapQuote << 120 | _reservedRate << 240;

        // Set as one mutex, the other are uninit, at 1
        delegate.ForTest_setMutexes(_mutex, 1, 1, 1);

        // mock the swap call reverting
        vm.mockCallRevert(
            address(pool),
            abi.encodeCall(
                pool.swap,
                (
                    address(delegate),
                    address(weth) < address(projectToken),
                    int256(1 ether),
                    address(projectToken) < address(weth) ? TickMath.MAX_SQRT_RATIO - 1 : TickMath.MIN_SQRT_RATIO + 1,
                    abi.encode(_twapQuote)
                )
            ),
            abi.encode("no swap")
        );

        // mock the call to the directory, to get the controller
        vm.mockCall(address(jbxTerminal), abi.encodeCall(jbxTerminal.directory, ()), abi.encode(address(directory)));
        vm.mockCall(
            address(directory),
            abi.encodeCall(directory.controllerOf, (didPayData.projectId)),
            abi.encode(address(controller))
        );

        // mock the minting call - this uses the weight and not the (potentially faulty) quote or twap
        vm.mockCall(
            address(controller),
            abi.encodeCall(
                controller.mintTokensOf,
                (didPayData.projectId, _tokenCount, dude, didPayData.memo, didPayData.preferClaimedTokens, true)
            ),
            abi.encode(true)
        );

        // mock the add to balance addint eth back to the terminal (need to deal eth as this transfer really occurs in test)
        vm.deal(address(delegate), 1 ether);
        vm.mockCall(
            address(jbxTerminal),
            abi.encodeCall(
                IJBPaymentTerminal(address(jbxTerminal)).addToBalanceOf,
                (didPayData.projectId, 1 ether, JBTokens.ETH, "", "")
            ),
            ""
        );

        // expect event
        vm.expectEmit(true, true, true, true);
        emit JBXBuybackDelegate_Mint(didPayData.projectId);

        vm.prank(address(jbxTerminal));
        delegate.didPay(didPayData);
    }

    /**
     * @notice Test didPay revert if wrong caller
     */
    function test_didPay_revertIfWrongCaller(address _notTerminal) public {
        vm.assume(_notTerminal != address(jbxTerminal));

        vm.expectRevert(abi.encodeWithSelector(JBXBuybackDelegate.JuiceBuyback_Unauthorized.selector));

        vm.prank(_notTerminal);
        delegate.didPay(didPayData);
    }

    /**
     * @notice Test uniswapCallback
     *
     * @dev    2 branches: project token is 0 or 1 in the pool slot0
     */
    function test_uniswapCallback() public {
        int256 _delta0 = -1 ether;
        int256 _delta1 = 1 ether;
        uint256 _minReceived = 25;

        /**
         * First branch
         */
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

        // If project is token0, then received is delta0 (the negative value)
        (_delta0, _delta1) = address(projectToken) < address(weth) ? (_delta0, _delta1) : (_delta1, _delta0);

        // mock and expect weth calls, this should transfer from delegate to pool (positive delta in the callback)
        vm.mockCall(address(weth), abi.encodeCall(weth.deposit, ()), "");

        vm.mockCall(
            address(weth),
            abi.encodeCall(
                weth.transfer, (address(pool), uint256(address(projectToken) < address(weth) ? _delta1 : _delta0))
            ),
            abi.encode(true)
        );

        vm.prank(address(pool));
        delegate.uniswapV3SwapCallback(_delta0, _delta1, abi.encode(_minReceived));

        /**
         * Second branch
         */

        // Invert both contract addresses, to swap token0 and token1
        projectToken = JBToken(address(weth));
        weth = IWETH9(address(projectToken));

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

        // mock and expect weth calls, this should transfer from delegate to pool (positive delta in the callback)
        vm.mockCall(address(weth), abi.encodeCall(weth.deposit, ()), "");

        vm.mockCall(
            address(weth),
            abi.encodeCall(
                weth.transfer, (address(pool), uint256(address(projectToken) < address(weth) ? _delta1 : _delta0))
            ),
            abi.encode(true)
        );

        vm.prank(address(pool));
        delegate.uniswapV3SwapCallback(_delta0, _delta1, abi.encode(_minReceived));
    }

    /**
     * @notice Test uniswapCallback revert if wrong caller
     */
    function test_uniswapCallback_revertIfWrongCaller() public {
        int256 _delta0 = -1 ether;
        int256 _delta1 = 1 ether;
        uint256 _minReceived = 25;

        vm.expectRevert(abi.encodeWithSelector(JBXBuybackDelegate.JuiceBuyback_Unauthorized.selector));
        delegate.uniswapV3SwapCallback(_delta0, _delta1, abi.encode(_minReceived));
    }

    /**
     * @notice Test uniswapCallback revert if max slippage
     */
    function test_uniswapCallback_revertIfMaxSlippage() public {
        int256 _delta0 = -1 ether;
        int256 _delta1 = 1 ether;
        uint256 _minReceived = 25 ether;

        // If project is token0, then received is delta0 (the negative value)
        (_delta0, _delta1) = address(projectToken) < address(weth) ? (_delta0, _delta1) : (_delta1, _delta0);

        vm.prank(address(pool));
        vm.expectRevert(abi.encodeWithSelector(JBXBuybackDelegate.JuiceBuyback_MaximumSlippage.selector));
        delegate.uniswapV3SwapCallback(_delta0, _delta1, abi.encode(_minReceived));
    }

    /**
     * @notice Test sweep
     */
    function test_Sweep() public {
        uint256 _tokenCount = 10;
        uint256 _twapQuote = 11;
        uint256 _reservedRate = 0;

        uint256 _mutex = _tokenCount | _twapQuote << 120 | _reservedRate << 240; // no reserved

        // Set as one mutex, the other are uninit, at 1
        delegate.ForTest_setMutexes(_mutex, 1, 1, 1);

        // mock the swap call
        vm.mockCall(
            address(pool),
            abi.encodeCall(
                pool.swap,
                (
                    address(delegate),
                    address(weth) < address(projectToken),
                    int256(1 ether),
                    address(projectToken) < address(weth) ? TickMath.MAX_SQRT_RATIO - 1 : TickMath.MIN_SQRT_RATIO + 1,
                    abi.encode(_twapQuote)
                )
            ),
            abi.encode(-int256(_twapQuote), -int256(_twapQuote))
        );

        // Mock the project token transfer
        vm.mockCall(address(projectToken), abi.encodeCall(projectToken.transfer, (dude, _twapQuote)), abi.encode(true));

        // Add some leftover (nothing will be wrapped/transfered as it happens in the callback)
        vm.deal(address(delegate), 10 ether);

        // check: correct event?
        vm.expectEmit(true, true, true, true);
        emit JBXBuybackDelegate_PendingSweep(dude, 10 ether);

        vm.prank(address(jbxTerminal));
        delegate.didPay(didPayData);

        // Check: correct overall sweep balance?
        assertEq(delegate.sweepBalance(), 10 ether);

        // Check: correct dude sweep balance
        assertEq(delegate.sweepBalanceOf(dude), 10 ether);

        uint256 _balanceBeforeSweep = dude.balance;

        // sweep
        vm.prank(dude);
        delegate.sweep(dude);

        uint256 _balanceAfterSweep = dude.balance;
        uint256 _sweptAmount = _balanceAfterSweep - _balanceBeforeSweep;

        // Check: correct overall sweep balance?
        assertEq(delegate.sweepBalance(), 0);

        // Check: correct dude sweep balance
        assertEq(delegate.sweepBalanceOf(dude), 0);

        // Check: correct swept balance
        assertEq(_sweptAmount, 10 ether);
    }

    /**
     * @notice Test sweep revert if transfer fails
     */
    function test_Sweep_revertIfTransferFails() public {
        uint256 _tokenCount = 10;
        uint256 _twapQuote = 11;
        uint256 _reservedRate = 0;

        uint256 _mutex = _tokenCount | _twapQuote << 120 | _reservedRate << 240; // no reserved

        // Set as one mutex, the other are uninit, at 1
        delegate.ForTest_setMutexes(_mutex, 1, 1, 1);

        // mock the swap call
        vm.mockCall(
            address(pool),
            abi.encodeCall(
                pool.swap,
                (
                    address(delegate),
                    address(weth) < address(projectToken),
                    int256(1 ether),
                    address(projectToken) < address(weth) ? TickMath.MAX_SQRT_RATIO - 1 : TickMath.MIN_SQRT_RATIO + 1,
                    abi.encode(_twapQuote)
                )
            ),
            abi.encode(-int256(_twapQuote), -int256(_twapQuote))
        );

        // Mock the project token transfer
        vm.mockCall(address(projectToken), abi.encodeCall(projectToken.transfer, (dude, _twapQuote)), abi.encode(true));

        // Add some leftover (nothing will be wrapped/transfered as it happens in the callback)
        vm.deal(address(delegate), 10 ether);

        // check: correct event?
        vm.expectEmit(true, true, true, true);
        emit JBXBuybackDelegate_PendingSweep(dude, 10 ether);

        vm.prank(address(jbxTerminal));
        delegate.didPay(didPayData);

        // Check: correct overall sweep balance?
        assertEq(delegate.sweepBalance(), 10 ether);

        // Check: correct dude sweep balance
        assertEq(delegate.sweepBalanceOf(dude), 10 ether);

        uint256 _balanceBeforeSweep = dude.balance;

        // no fallback -> will revert
        vm.etch(dude, '6969');

        // Check: revert?
        vm.prank(dude);
        vm.expectRevert(abi.encodeWithSelector(JBXBuybackDelegate.JuiceBuyback_TransferFailed.selector));
        delegate.sweep(dude);
    }
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
    )
        JBXBuybackDelegate(_projectToken, _weth, _pool, _secondsAgo, _twapDelta, _jbxTerminal, _projects, _operatorStore)
    {}

    function ForTest_mutexCommon() external view returns (uint256) {
        return mutexCommon;
    }

    function ForTest_mutexReservedRate() external view returns (uint256) {
        return mutexReservedRate;
    }

    function ForTest_mutexSwapQuote() external view returns (uint256) {
        return mutexSwapQuote;
    }

    function ForTest_setMutexes(
        uint256 _mutexCommon,
        uint256 _mutexSwap,
        uint256 _mutexReservedRate,
        uint256 _fakeBoolUse3
    ) external {
        mutexCommon = _mutexCommon;
        mutexSwapQuote = _mutexSwap;
        mutexReservedRate = _mutexReservedRate;
        useThreeMutexes = _fakeBoolUse3;
    }

    function ForTest_getQuote(uint256 _amountIn) external view returns (uint256 _amountOut) {
        return _getQuote(_amountIn);
    }
}
