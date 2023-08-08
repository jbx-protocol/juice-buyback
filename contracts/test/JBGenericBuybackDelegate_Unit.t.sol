// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import "../interfaces/external/IWETH9.sol";
import "./helpers/TestBaseWorkflowV3.sol";

import "@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBController3_1.sol";
import "@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBDirectory.sol";
import "@jbx-protocol/juice-contracts-v3/contracts/libraries/JBConstants.sol";
import "@jbx-protocol/juice-contracts-v3/contracts/libraries/JBTokens.sol";

import {JBDelegateMetadataHelper} from "@jbx-protocol/juice-delegate-metadata-lib/src/JBDelegateMetadataHelper.sol";

import "@paulrberg/contracts/math/PRBMath.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import "forge-std/Test.sol";

import "../JBGenericBuybackDelegate.sol";
import "../libraries/JBBuybackDelegateOperations.sol";

/**
 * @notice Unit tests for the JBGenericBuybackDelegate contract.
 *
 */
contract TestJBGenericBuybackDelegate_Units is Test {
    using stdStorage for StdStorage;

    ForTest_JBGenericBuybackDelegate delegate;

    event BuybackDelegate_Swap(uint256 indexed projectId, uint256 amountEth, uint256 amountOut);
    event BuybackDelegate_Mint(uint256 indexed projectId);
    event BuybackDelegate_SecondsAgoChanged(uint256 indexed projectId, uint256 oldSecondsAgo, uint256 newSecondsAgo);
    event BuybackDelegate_TwapDeltaChanged(uint256 indexed projectId, uint256 oldTwapDelta, uint256 newTwapDelta);
    event BuybackDelegate_PendingSweep(address indexed beneficiary, address indexed token, uint256 amount);
    event BuybackDelegate_PoolAdded(uint256 indexed projectId, address indexed terminalToken, address newPool);

    // Use the L1 UniswapV3Pool jbx/eth 1% fee for create2 magic
    IUniswapV3Pool pool = IUniswapV3Pool(0x48598Ff1Cee7b4d31f8f9050C2bbAE98e17E6b17);
    IERC20 projectToken = IERC20(0x3abF2A4f8452cCC2CF7b4C1e4663147600646f66);
    IWETH9 weth = IWETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    uint24 fee = 10000;

    // A random non-weth pool: The PulseDogecoin Staking Carnival Token/HEX @ 0.3%
    IERC20 otherRandomProjectToken = IERC20(0x2b591e99afE9f32eAA6214f7B7629768c40Eeb39);
    IERC20 randomTerminalToken = IERC20(0x488Db574C77dd27A07f9C97BAc673BC8E9fC6Bf3);
    IUniswapV3Pool randomPool = IUniswapV3Pool(0x7668B2Ea8490955F68F5c33E77FE150066c94fb9);
    uint24 randomFee = 3000;
    uint256 randomId = 420;

    address _uniswapFactory = 0x1F98431c8aD98523631AE4a59f267346ea31F984;

    IJBPayoutRedemptionPaymentTerminal3_1_1 jbxTerminal =
        IJBPayoutRedemptionPaymentTerminal3_1_1(makeAddr("IJBPayoutRedemptionPaymentTerminal3_1"));
    IJBProjects projects = IJBProjects(makeAddr("IJBProjects"));
    IJBOperatorStore operatorStore = IJBOperatorStore(makeAddr("IJBOperatorStore"));
    IJBController3_1 controller = IJBController3_1(makeAddr("controller"));
    IJBDirectory directory = IJBDirectory(makeAddr("directory"));

    JBDelegateMetadataHelper metadataHelper = new JBDelegateMetadataHelper();

    address terminalStore = makeAddr("terminalStore");

    address dude = makeAddr("dude");
    address owner = makeAddr("owner");

    uint32 secondsAgo = 100;
    uint256 twapDelta = 100;

    uint256 projectId = 69;

    JBPayParamsData payParams = JBPayParamsData({
        terminal: jbxTerminal,
        payer: dude,
        amount: JBTokenAmount({token: address(weth), value: 1 ether, decimals: 18, currency: 1}),
        projectId: projectId,
        currentFundingCycleConfiguration: 0,
        beneficiary: dude,
        weight: 69,
        reservedRate: 0,
        memo: "myMemo",
        metadata: ""
    });

    JBDidPayData3_1_1 didPayData = JBDidPayData3_1_1({
        payer: dude,
        projectId: projectId,
        currentFundingCycleConfiguration: 0,
        amount: JBTokenAmount({token: JBTokens.ETH, value: 1 ether, decimals: 18, currency: 1}),
        forwardedAmount: JBTokenAmount({token: JBTokens.ETH, value: 1 ether, decimals: 18, currency: 1}),
        projectTokenCount: 69,
        beneficiary: dude,
        preferClaimedTokens: true,
        memo: "myMemo",
        dataSourceMetadata: "",
        payerMetadata: ""
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

        vm.label(address(pool), "pool");
        vm.label(address(projectToken), "projectToken");
        vm.label(address(weth), "weth");

        vm.mockCall(address(jbxTerminal), abi.encodeCall(jbxTerminal.store, ()), abi.encode(terminalStore));
        vm.mockCall(address(controller), abi.encodeCall(IJBOperatable.operatorStore, ()), abi.encode(operatorStore));
        vm.mockCall(address(controller), abi.encodeCall(controller.projects, ()), abi.encode(projects));

        vm.mockCall(address(projects), abi.encodeCall(projects.ownerOf, (projectId)), abi.encode(owner));

        vm.mockCall(address(jbxTerminal), abi.encodeCall(IJBSingleTokenPaymentTerminal.token, ()), abi.encode(weth));

        vm.prank(owner);
        delegate = new ForTest_JBGenericBuybackDelegate({
            _weth: weth,
            _factory: _uniswapFactory,
            _directory: directory,
            _controller: controller,
            _id: bytes4(hex'69')
        });

        delegate.ForTest_initPool(pool, projectId, secondsAgo, twapDelta, address(projectToken), address(weth)); 
        delegate.ForTest_initPool(randomPool, randomId, secondsAgo, twapDelta, address(otherRandomProjectToken), address(randomTerminalToken)); 
    }

    /**
     * @notice Test payParams when a quote is provided as metadata
     *
     * @dev    _tokenCount == weight, as we use a value of 1.
     */
    function test_payParams_callWithQuote(uint256 _tokenCount, uint256 _swapOutCount, uint256 _slippage) public {
        // Avoid overflow when computing slippage (cannot swap uint256.max tokens)
        _swapOutCount = bound(_swapOutCount, 1, type(uint240).max);

        _slippage = bound(_slippage, 1, 10000);

        // Take max slippage into account
        uint256 _swapQuote = _swapOutCount - ((_swapOutCount * _slippage) / 10000);

        // Pass the quote as metadata
        bytes[] memory _data = new bytes[](1);
        _data[0] = abi.encode(_swapOutCount, _slippage);

        // Pass the delegate id
        bytes4[] memory _ids = new bytes4[](1);
        _ids[0] = bytes4(hex"69");

        // Generate the metadata
        bytes memory _metadata = metadataHelper.createMetadata(_ids, _data);

        // Set the relevant payParams data
        payParams.weight = _tokenCount;
        payParams.metadata = _metadata;

        // Returned values to catch:
        JBPayDelegateAllocation3_1_1[] memory _allocationsReturned;
        string memory _memoReturned;
        uint256 _weightReturned;

        // Test: call payParams
        vm.prank(terminalStore);
        (_weightReturned, _memoReturned, _allocationsReturned) = delegate.payParams(payParams);

        // Mint pathway if more token received when minting:
        if (_tokenCount >= _swapQuote) {
            // No delegate allocation returned
            assertEq(_allocationsReturned.length, 0);

            // weight unchanged
            assertEq(_weightReturned, _tokenCount);
        }
        // Swap pathway (return the delegate allocation)
        else {
            assertEq(_allocationsReturned.length, 1);
            assertEq(address(_allocationsReturned[0].delegate), address(delegate));
            assertEq(_allocationsReturned[0].amount, 1 ether);
            assertEq(_allocationsReturned[0].metadata, abi.encode(_tokenCount, _swapQuote, projectToken));

            assertEq(_weightReturned, 0);
        }

        // Same memo in any case
        assertEq(_memoReturned, payParams.memo);
    }

    /**
     * @notice Test payParams when no quote is provided, falling back on the pool twap
     *
     * @dev    This bypass testing Uniswap Oracle lib by re-using the internal _getQuote
     */
    function test_payParams_useTwap(uint256 _tokenCount) public {
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
        JBPayDelegateAllocation3_1_1[] memory _allocationsReturned;
        string memory _memoReturned;
        uint256 _weightReturned;

        // Test: call payParams
        vm.prank(terminalStore);
        (_weightReturned, _memoReturned, _allocationsReturned) = delegate.payParams(payParams);

        // Bypass testing uniswap oracle lib
        uint256 _twapAmountOut = delegate.ForTest_getQuote(projectId, jbxTerminal, address(projectToken), 1 ether);

        // Mint pathway if more token received when minting:
        if (_tokenCount >= _twapAmountOut) {
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
            assertEq(_allocationsReturned[0].metadata, abi.encode(_tokenCount, _twapAmountOut, projectToken));

            assertEq(_weightReturned, 0);
        }

        // Same memo in any case
        assertEq(_memoReturned, payParams.memo);
    }

    /**
     * @notice Test payParams with a twap but locked pool, which should then mint
     */
    function test_payParams_useTwapLockedPool(uint256 _tokenCount) public {
        _tokenCount = bound(_tokenCount, 1, type(uint120).max);

        // Set the relevant payParams data
        payParams.weight = _tokenCount;
        payParams.metadata = "";

        // Mock the pool being unlocked
        vm.mockCall(address(pool), abi.encodeCall(pool.slot0, ()), abi.encode(0, 0, 0, 0, 0, 0, false));
        vm.expectCall(address(pool), abi.encodeCall(pool.slot0, ()));

        // Returned values to catch:
        JBPayDelegateAllocation3_1_1[] memory _allocationsReturned;
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
    }

    /**
     * @notice Test didPay with token received from swapping
     */
    function test_didPay_swap_ETH(uint256 _tokenCount, uint256 _twapQuote, uint256 _reservedRate) public {
        // Bound to avoid overflow and insure swap quote > mint quote
        _tokenCount = bound(_tokenCount, 2, type(uint256).max - 1);
        _twapQuote = bound(_twapQuote, _tokenCount + 1, type(uint256).max);
        _reservedRate = bound(_reservedRate, 0, 10000);

        // The metadata coming from payParams(..)
        didPayData.dataSourceMetadata = abi.encode(_tokenCount, _twapQuote, projectToken);

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
                    abi.encode(projectId, _twapQuote, weth, projectToken)
                )
            ),
            abi.encode(-int256(_twapQuote), -int256(_twapQuote))
        );
        vm.expectCall(
            address(pool),
            abi.encodeCall(
                pool.swap,
                (
                    address(delegate),
                    address(weth) < address(projectToken),
                    int256(1 ether),
                    address(projectToken) < address(weth) ? TickMath.MAX_SQRT_RATIO - 1 : TickMath.MIN_SQRT_RATIO + 1,
                    abi.encode(projectId, _twapQuote, weth, projectToken)
                )
            )
        );

        // mock call to pass the authorization check
        vm.mockCall(
            address(directory),
            abi.encodeCall(directory.isTerminalOf, (didPayData.projectId, IJBPaymentTerminal(address(jbxTerminal)))),
            abi.encode(true)
        );
        vm.expectCall(
            address(directory),
            abi.encodeCall(directory.isTerminalOf, (didPayData.projectId, IJBPaymentTerminal(address(jbxTerminal))))
        );

        // mock the burn call
        vm.mockCall(
            address(controller),
            abi.encodeCall(controller.burnTokensOf, (address(delegate), didPayData.projectId, _twapQuote, "", true)),
            abi.encode(true)
        );
        vm.expectCall(
            address(controller),
            abi.encodeCall(controller.burnTokensOf, (address(delegate), didPayData.projectId, _twapQuote, "", true))
        );

        // mock the minting call
        vm.mockCall(
            address(controller),
            abi.encodeCall(
                controller.mintTokensOf, (didPayData.projectId, _twapQuote, address(dude), didPayData.memo, true, true)
            ),
            abi.encode(true)
        );
        vm.expectCall(
            address(controller),
            abi.encodeCall(
                controller.mintTokensOf, (didPayData.projectId, _twapQuote, address(dude), didPayData.memo, true, true)
            )
        );

        // expect event
        vm.expectEmit(true, true, true, true);
        emit BuybackDelegate_Swap(didPayData.projectId, didPayData.amount.value, _twapQuote);

        vm.prank(address(jbxTerminal));
        delegate.didPay(didPayData);
    }

    /**
     * @notice Test didPay with token received from swapping
     */
    function test_didPay_swap_ERC20(uint256 _tokenCount, uint256 _twapQuote, uint256 _reservedRate) public {
        // Bound to avoid overflow and insure swap quote > mint quote
        _tokenCount = bound(_tokenCount, 2, type(uint256).max - 1);
        _twapQuote = bound(_twapQuote, _tokenCount + 1, type(uint256).max);
        _reservedRate = bound(_reservedRate, 0, 10000);

        didPayData.amount = JBTokenAmount({token: address(randomTerminalToken), value: 1 ether, decimals: 18, currency: 1});
        didPayData.forwardedAmount = JBTokenAmount({token: address(randomTerminalToken), value: 1 ether, decimals: 18, currency: 1});
        didPayData.projectId = randomId;

        // The metadata coming from payParams(..)
        didPayData.dataSourceMetadata = abi.encode(_tokenCount, _twapQuote, otherRandomProjectToken);

        // mock the swap call
        vm.mockCall(
            address(randomPool),
            abi.encodeCall(
                randomPool.swap,
                (
                    address(delegate),
                    address(randomTerminalToken) < address(otherRandomProjectToken),
                    int256(1 ether),
                    address(otherRandomProjectToken) < address(randomTerminalToken) ? TickMath.MAX_SQRT_RATIO - 1 : TickMath.MIN_SQRT_RATIO + 1,
                    abi.encode(randomId, _twapQuote, randomTerminalToken, otherRandomProjectToken)
                )
            ),
            abi.encode(-int256(_twapQuote), -int256(_twapQuote))
        );
        vm.expectCall(
            address(randomPool),
            abi.encodeCall(
                randomPool.swap,
                (
                    address(delegate),
                    address(randomTerminalToken) < address(otherRandomProjectToken),
                    int256(1 ether),
                    address(otherRandomProjectToken) < address(randomTerminalToken) ? TickMath.MAX_SQRT_RATIO - 1 : TickMath.MIN_SQRT_RATIO + 1,
                    abi.encode(randomId, _twapQuote, randomTerminalToken, otherRandomProjectToken)
                )
            )
        );

        // mock call to pass the authorization check
        vm.mockCall(
            address(directory),
            abi.encodeCall(directory.isTerminalOf, (didPayData.projectId, IJBPaymentTerminal(address(jbxTerminal)))),
            abi.encode(true)
        );
        vm.expectCall(
            address(directory),
            abi.encodeCall(directory.isTerminalOf, (didPayData.projectId, IJBPaymentTerminal(address(jbxTerminal))))
        );

        // mock the burn call
        vm.mockCall(
            address(controller),
            abi.encodeCall(controller.burnTokensOf, (address(delegate), didPayData.projectId, _twapQuote, "", true)),
            abi.encode(true)
        );
        vm.expectCall(
            address(controller),
            abi.encodeCall(controller.burnTokensOf, (address(delegate), didPayData.projectId, _twapQuote, "", true))
        );

        // mock the minting call
        vm.mockCall(
            address(controller),
            abi.encodeCall(
                controller.mintTokensOf, (didPayData.projectId, _twapQuote, address(dude), didPayData.memo, true, true)
            ),
            abi.encode(true)
        );
        vm.expectCall(
            address(controller),
            abi.encodeCall(
                controller.mintTokensOf, (didPayData.projectId, _twapQuote, address(dude), didPayData.memo, true, true)
            )
        );

        // No leftover
        vm.mockCall(address(randomTerminalToken), abi.encodeCall(randomTerminalToken.balanceOf, (address(delegate))), abi.encode(0));
        vm.expectCall(address(randomTerminalToken), abi.encodeCall(randomTerminalToken.balanceOf, (address(delegate))));

        // expect event
        vm.expectEmit(true, true, true, true);
        emit BuybackDelegate_Swap(didPayData.projectId, didPayData.amount.value, _twapQuote);

        vm.prank(address(jbxTerminal));
        delegate.didPay(didPayData);
    }

    /**
     * @notice Test didPay when eth leftover from swap
     */
    function test_didPay_keepTrackOfETHToSweep() public {
        uint256 _tokenCount = 10;
        uint256 _twapQuote = 11;

        // The metadata coming from payParams(..)
        didPayData.dataSourceMetadata = abi.encode(_tokenCount, _twapQuote, projectToken);

        // Add some leftover
        vm.deal(address(delegate), 10 ether);

        // Add a previous leftover, to test the incremental accounting (ie 5 out of 10 were there)
        stdstore.target(address(delegate)).sig("totalUnclaimedBalance(address)").with_key(JBTokens.ETH).checked_write(5 ether);

        // Out of these 5, 1 was for payer
        stdstore.target(address(delegate)).sig("sweepBalanceOf(address,address)").with_key(didPayData.payer).with_key(JBTokens.ETH).checked_write(
            1 ether
        );

        // mock call to pass the authorization check
        vm.mockCall(
            address(directory),
            abi.encodeCall(directory.isTerminalOf, (didPayData.projectId, IJBPaymentTerminal(address(jbxTerminal)))),
            abi.encode(true)
        );
        vm.expectCall(
            address(directory),
            abi.encodeCall(directory.isTerminalOf, (didPayData.projectId, IJBPaymentTerminal(address(jbxTerminal))))
        );

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
                    abi.encode(projectId, _twapQuote, weth, projectToken)
                )
            ),
            abi.encode(-int256(_twapQuote), -int256(_twapQuote))
        );
        vm.expectCall(
            address(pool),
            abi.encodeCall(
                pool.swap,
                (
                    address(delegate),
                    address(weth) < address(projectToken),
                    int256(1 ether),
                    address(projectToken) < address(weth) ? TickMath.MAX_SQRT_RATIO - 1 : TickMath.MIN_SQRT_RATIO + 1,
                    abi.encode(projectId, _twapQuote, weth, projectToken)
                )
            )
        );

        // mock the burn call
        vm.mockCall(
            address(controller),
            abi.encodeCall(controller.burnTokensOf, (address(delegate), didPayData.projectId, _twapQuote, "", true)),
            abi.encode(true)
        );
        vm.expectCall(
            address(controller),
            abi.encodeCall(controller.burnTokensOf, (address(delegate), didPayData.projectId, _twapQuote, "", true))
        );

        // mock the minting call
        vm.mockCall(
            address(controller),
            abi.encodeCall(
                controller.mintTokensOf, (didPayData.projectId, _twapQuote, address(dude), didPayData.memo, didPayData.preferClaimedTokens, true)
            ),
            abi.encode(true)
        );
        vm.expectCall(
            address(controller),
            abi.encodeCall(
                controller.mintTokensOf, (didPayData.projectId, _twapQuote, address(dude), didPayData.memo, didPayData.preferClaimedTokens, true)
            )
        );

        // check: correct event?
        vm.expectEmit(true, true, true, true);
        emit BuybackDelegate_PendingSweep(dude, JBTokens.ETH, 5 ether);

        vm.prank(address(jbxTerminal));
        delegate.didPay(didPayData);

        // Check: correct overall sweep balance?
        assertEq(delegate.totalUnclaimedBalance(JBTokens.ETH), 10 ether);

        // Check: correct dude sweep balance (1 previous plus 5 from now)?
        assertEq(delegate.sweepBalanceOf(dude, JBTokens.ETH), 6 ether);
    }

    /**
     * @notice Test didPay with swap reverting, should then mint
     */

    function test_didPay_swapRevert(uint256 _tokenCount, uint256 _twapQuote) public {
        _tokenCount = bound(_tokenCount, 2, type(uint256).max - 1);
        _twapQuote = bound(_twapQuote, _tokenCount + 1, type(uint256).max);

        // The metadata coming from payParams(..)
        didPayData.dataSourceMetadata = abi.encode(_tokenCount, _twapQuote, projectToken);

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
                    abi.encode(projectId, _twapQuote, weth, projectToken)
                )
            ),
            abi.encode("no swap")
        );

        // mock call to pass the authorization check
        vm.mockCall(
            address(directory),
            abi.encodeCall(directory.isTerminalOf, (didPayData.projectId, IJBPaymentTerminal(address(jbxTerminal)))),
            abi.encode(true)
        );
        vm.expectCall(
            address(directory),
            abi.encodeCall(directory.isTerminalOf, (didPayData.projectId, IJBPaymentTerminal(address(jbxTerminal))))
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
        vm.expectCall(
            address(controller),
            abi.encodeCall(
                controller.mintTokensOf,
                (didPayData.projectId, _tokenCount, dude, didPayData.memo, didPayData.preferClaimedTokens, true)
            )
        );

        // mock the add to balance adding eth back to the terminal (need to deal eth as this transfer really occurs in test)
        vm.deal(address(delegate), 1 ether);
        vm.mockCall(
            address(jbxTerminal),
            abi.encodeCall(
                IJBPaymentTerminal(address(jbxTerminal)).addToBalanceOf,
                (didPayData.projectId, 1 ether, JBTokens.ETH, "", "")
            ),
            ""
        );
        vm.expectCall(
            address(jbxTerminal),
            abi.encodeCall(
                IJBPaymentTerminal(address(jbxTerminal)).addToBalanceOf,
                (didPayData.projectId, 1 ether, JBTokens.ETH, "", "")
            )
        );

        // expect event
        vm.expectEmit(true, true, true, true);
        emit BuybackDelegate_Mint(didPayData.projectId);

        vm.prank(address(jbxTerminal));
        delegate.didPay(didPayData);
    }

    /**
     * @notice Test didPay with swap reverting, should then mint
     */
    function test_didPay_swapRevert_ERC20(uint256 _tokenCount, uint256 _twapQuote) public {
        _tokenCount = bound(_tokenCount, 2, type(uint256).max - 1);
        _twapQuote = bound(_twapQuote, _tokenCount + 1, type(uint256).max);

        didPayData.amount = JBTokenAmount({token: address(randomTerminalToken), value: 1 ether, decimals: 18, currency: 1});
        didPayData.forwardedAmount = JBTokenAmount({token: address(randomTerminalToken), value: 1 ether, decimals: 18, currency: 1});
        didPayData.projectId = randomId;

        vm.mockCall(address(jbxTerminal), abi.encodeCall(IJBSingleTokenPaymentTerminal.token, ()), abi.encode(randomTerminalToken));

        // The metadata coming from payParams(..)
        didPayData.dataSourceMetadata = abi.encode(_tokenCount, _twapQuote, otherRandomProjectToken);

        // mock the swap call reverting
        vm.mockCallRevert(
            address(randomPool),
            abi.encodeCall(
                randomPool.swap,
                (
                    address(delegate),
                    address(randomTerminalToken) < address(otherRandomProjectToken),
                    int256(1 ether),
                    address(otherRandomProjectToken) < address(randomTerminalToken) ? TickMath.MAX_SQRT_RATIO - 1 : TickMath.MIN_SQRT_RATIO + 1,
                    abi.encode(randomId, _twapQuote, randomTerminalToken, otherRandomProjectToken)
                )
            ),
            abi.encode("no swap")
        );

        // mock call to pass the authorization check
        vm.mockCall(
            address(directory),
            abi.encodeCall(directory.isTerminalOf, (didPayData.projectId, IJBPaymentTerminal(address(jbxTerminal)))),
            abi.encode(true)
        );
        vm.expectCall(
            address(directory),
            abi.encodeCall(directory.isTerminalOf, (didPayData.projectId, IJBPaymentTerminal(address(jbxTerminal))))
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
        vm.expectCall(
            address(controller),
            abi.encodeCall(
                controller.mintTokensOf,
                (didPayData.projectId, _tokenCount, dude, didPayData.memo, didPayData.preferClaimedTokens, true)
            )
        );

        // mock the add to balance adding eth back to the terminal (need to deal eth as this transfer really occurs in test)
        vm.deal(address(delegate), 1 ether);
        vm.mockCall(
            address(jbxTerminal),
            abi.encodeCall(
                IJBPaymentTerminal(address(jbxTerminal)).addToBalanceOf,
                (didPayData.projectId, 1 ether, address(randomTerminalToken), "", "")
            ),
            ""
        );
        vm.expectCall(
            address(jbxTerminal),
            abi.encodeCall(
                IJBPaymentTerminal(address(jbxTerminal)).addToBalanceOf,
                (didPayData.projectId, 1 ether, address(randomTerminalToken), "", "")
            )
        );

        // Mock the approval for the addToBalance
        vm.mockCall(
            address(randomTerminalToken),
            abi.encodeCall(randomTerminalToken.approve, (address(jbxTerminal), 1 ether)),
            abi.encode(true)
        );
        vm.expectCall(
            address(randomTerminalToken),
            abi.encodeCall(randomTerminalToken.approve, (address(jbxTerminal), 1 ether))
        );

        // Mock the no leftover
        vm.mockCall(address(randomTerminalToken), abi.encodeCall(randomTerminalToken.balanceOf, (address(delegate))), abi.encode(0));
        vm.expectCall(address(randomTerminalToken), abi.encodeCall(randomTerminalToken.balanceOf, (address(delegate))));

        // expect event
        vm.expectEmit(true, true, true, true);
        emit BuybackDelegate_Mint(didPayData.projectId);

        vm.prank(address(jbxTerminal));
        delegate.didPay(didPayData);
    }

    /**
     * @notice Test didPay revert if wrong caller
     */
    function test_didPay_revertIfWrongCaller(address _notTerminal) public {
        vm.assume(_notTerminal != address(jbxTerminal));

        // mock call to fail at the authorization check since directory has no bytecode
        vm.mockCall(
            address(directory),
            abi.encodeCall(directory.isTerminalOf, (didPayData.projectId, IJBPaymentTerminal(address(_notTerminal)))),
            abi.encode(false)
        );
        vm.expectCall(
            address(directory),
            abi.encodeCall(directory.isTerminalOf, (didPayData.projectId, IJBPaymentTerminal(address(_notTerminal))))
        );

        vm.expectRevert(abi.encodeWithSelector(JBGenericBuybackDelegate.JuiceBuyback_Unauthorized.selector));

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
        delegate = new ForTest_JBGenericBuybackDelegate({
            _weth: weth,
            _factory: _uniswapFactory,
            _directory: directory,
            _controller: controller,
            _id: bytes4(hex'69')
        });

        delegate.ForTest_initPool(pool, projectId, secondsAgo, twapDelta, address(projectToken), address(weth)); 

        // If project is token0, then received is delta0 (the negative value)
        (_delta0, _delta1) = address(projectToken) < address(weth) ? (_delta0, _delta1) : (_delta1, _delta0);

        // mock and expect weth calls, this should transfer from delegate to pool (positive delta in the callback)
        vm.mockCall(address(weth), abi.encodeCall(weth.deposit, ()), "");
        vm.expectCall(address(weth), abi.encodeCall(weth.deposit, ()));

        vm.mockCall(
            address(weth),
            abi.encodeCall(
                weth.transfer, (address(pool), uint256(address(projectToken) < address(weth) ? _delta1 : _delta0))
            ),
            abi.encode(true)
        );
        vm.expectCall(
            address(weth),
            abi.encodeCall(
                weth.transfer, (address(pool), uint256(address(projectToken) < address(weth) ? _delta1 : _delta0))
            )
        );

        vm.prank(address(pool));
        delegate.uniswapV3SwapCallback(_delta0, _delta1, abi.encode(projectId, _minReceived, JBTokens.ETH, projectToken));

        /**
         * Second branch
         */

        // Invert both contract addresses, to swap token0 and token1 (this will NOT modify the pool address)
        (projectToken, weth) = (JBToken(address(weth)), IWETH9(address(projectToken)));

        delegate = new ForTest_JBGenericBuybackDelegate({
            _weth: weth,
            _factory: _uniswapFactory,
            _directory: directory,
            _controller: controller,
            _id: bytes4(hex'69')
        });
    
        delegate.ForTest_initPool(pool, projectId, secondsAgo, twapDelta, address(projectToken), address(weth)); 

        vm.mockCall(
            address(weth),
            abi.encodeCall(
                weth.transfer, (address(pool), uint256(address(projectToken) < address(weth) ? _delta1 : _delta0))
            ),
            abi.encode(true)
        );
        vm.expectCall(
            address(weth),
            abi.encodeCall(
                weth.transfer, (address(pool), uint256(address(projectToken) < address(weth) ? _delta1 : _delta0))
            )
        );

        vm.prank(address(pool));
        delegate.uniswapV3SwapCallback(_delta0, _delta1, abi.encode(projectId, _minReceived, weth, projectToken));
    }

    /**
     * @notice Test uniswapCallback revert if wrong caller
     */
    function test_uniswapCallback_revertIfWrongCaller() public {
        int256 _delta0 = -1 ether;
        int256 _delta1 = 1 ether;
        uint256 _minReceived = 25;

        vm.expectRevert(abi.encodeWithSelector(JBGenericBuybackDelegate.JuiceBuyback_Unauthorized.selector));
        delegate.uniswapV3SwapCallback(_delta0, _delta1, abi.encode(projectId, _minReceived, weth, projectToken));
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
        vm.expectRevert(abi.encodeWithSelector(JBGenericBuybackDelegate.JuiceBuyback_MaximumSlippage.selector));
        delegate.uniswapV3SwapCallback(_delta0, _delta1, abi.encode(projectId, _minReceived, weth, projectToken));
    }

    /**
     * @notice Test sweep
     */
    function test_sweep_erc20(uint256 _delegateLeftover, uint256 _dudeLeftover) public {
        _dudeLeftover = bound(_dudeLeftover, 0, _delegateLeftover);

        // Store the delegate leftover
        stdstore.target(address(delegate)).sig("totalUnclaimedBalance(address)").with_key(address(weth)).checked_write(_delegateLeftover);

        // Store the dude leftover
        stdstore.target(address(delegate)).sig("sweepBalanceOf(address,address)").with_key(dude).with_key(address(weth)).checked_write(
            _dudeLeftover
        );

        if(_dudeLeftover > 0) {
            vm.mockCall(address(weth), abi.encodeCall(weth.transfer, (dude, _dudeLeftover)), abi.encode(true));
            vm.expectCall(address(weth), abi.encodeCall(weth.transfer, (dude, _dudeLeftover)));
        }

        // Test: sweep
        vm.prank(dude);
        delegate.sweep(dude, address(weth));

        // Check: correct overall sweep balance?
        assertEq(delegate.totalUnclaimedBalance(address(weth)), _delegateLeftover - _dudeLeftover);

        // Check: correct dude sweep balance
        assertEq(delegate.sweepBalanceOf(dude, address(weth)), 0);
    }

    /**
     * @notice Test sweep
     */
    function test_sweep_eth(uint256 _delegateLeftover, uint256 _dudeLeftover) public {
        _dudeLeftover = bound(_dudeLeftover, 0, _delegateLeftover);

        // Add the ETH
        vm.deal(address(delegate), _delegateLeftover);

        // Store the delegate leftover
        stdstore.target(address(delegate)).sig("totalUnclaimedBalance(address)").with_key(JBTokens.ETH).checked_write(_delegateLeftover);

        // Store the dude leftover
        stdstore.target(address(delegate)).sig("sweepBalanceOf(address,address)").with_key(dude).with_key(JBTokens.ETH).checked_write(
            _dudeLeftover
        );

        uint256 _balanceBeforeSweep = dude.balance;

        // Test: sweep
        vm.prank(dude);
        delegate.sweep(dude, JBTokens.ETH);

        uint256 _balanceAfterSweep = dude.balance;
        uint256 _sweptAmount = _balanceAfterSweep - _balanceBeforeSweep;

        // Check: correct overall sweep balance?
        assertEq(delegate.totalUnclaimedBalance(JBTokens.ETH), _delegateLeftover - _dudeLeftover);

        // Check: correct dude sweep balance
        assertEq(delegate.sweepBalanceOf(dude, JBTokens.ETH), 0);

        // Check: correct swept balance
        assertEq(_sweptAmount, _dudeLeftover);
    }

    /**
     * @notice Test sweep revert if transfer fails
     */
    function test_sweep_revertIfTransferFails() public {
        // Store the delegate total leftover
        stdstore.target(address(delegate)).sig("totalUnclaimedBalance(address)").with_key(JBTokens.ETH).checked_write(1 ether);

        // Store the dude leftover
        stdstore.target(address(delegate)).sig("sweepBalanceOf(address,address)").with_key(dude).with_key(JBTokens.ETH).checked_write(
            1 ether
        );

        // Deal enough ETH
        vm.deal(address(delegate), 1 ether);

        // no fallback -> will revert
        vm.etch(dude, "6969");

        // Check: revert?
        vm.prank(dude);
        vm.expectRevert(abi.encodeWithSelector(JBGenericBuybackDelegate.JuiceBuyback_TransferFailed.selector));
        delegate.sweep(dude, JBTokens.ETH);
    }

    /**
     * @notice Test increase seconds ago
     */
    function test_changeSecondsAgo(uint256 _newValue) public {
        _newValue = bound(_newValue, 0, type(uint32).max);

        // check: correct event?
        vm.expectEmit(true, true, true, true);
        emit BuybackDelegate_SecondsAgoChanged(projectId, delegate.secondsAgoOf(projectId), _newValue);

        // Test: change seconds ago
        vm.prank(owner);
        delegate.changeSecondsAgo(projectId, uint32(_newValue));

        // Check: correct seconds ago?
        assertEq(delegate.secondsAgoOf(projectId), _newValue);
    }

    /**
     * @notice Test increase seconds ago revert if wrong caller
     */
    function test_changeSecondsAgo_revertIfWrongCaller(address _notOwner) public {
        vm.assume(owner != _notOwner);

        vm.mockCall(
            address(operatorStore),
            abi.encodeCall(operatorStore.hasPermission, (_notOwner, owner, projectId, JBBuybackDelegateOperations.MODIFY_POOL)), 
            abi.encode(false)
        );
        vm.expectCall(
            address(operatorStore),
            abi.encodeCall(operatorStore.hasPermission, (_notOwner, owner, projectId, JBBuybackDelegateOperations.MODIFY_POOL))
        );

        vm.mockCall(
            address(operatorStore),
            abi.encodeCall(operatorStore.hasPermission, (_notOwner, owner, 0, JBBuybackDelegateOperations.MODIFY_POOL)), 
            abi.encode(false)
        );
        vm.expectCall(
            address(operatorStore),
            abi.encodeCall(operatorStore.hasPermission, (_notOwner, owner, 0, JBBuybackDelegateOperations.MODIFY_POOL))
        );

        // check: revert?
        vm.expectRevert(abi.encodeWithSignature("UNAUTHORIZED()"));

        // Test: change seconds ago (left uninit/at 0)
        vm.startPrank(_notOwner);
        delegate.changeSecondsAgo(projectId, 999);
    }

    /**
     * @notice Test set twap delta
     */
    function test_setTwapDelta(uint256 _oldDelta, uint256 _newDelta) public {
        // Store a preexisting twap delta
        stdstore.target(address(delegate)).sig("twapDeltaOf(uint256)").with_key(projectId).checked_write(_oldDelta);

        // Check: correct event?
        vm.expectEmit(true, true, true, true);
        emit BuybackDelegate_TwapDeltaChanged(projectId, _oldDelta, _newDelta);

        // Test: set the twap
        vm.prank(owner);
        delegate.setTwapDelta(projectId, _newDelta);

        // Check: correct twap?
        assertEq(delegate.twapDeltaOf(projectId), _newDelta);
    }

    /**
     * @notice Test set twap delta reverts if wrong caller
     */
    function test_setTwapDelta_revertWrongCaller(address _notOwner) public {
        vm.assume(owner != _notOwner);

        vm.mockCall(
            address(operatorStore),
            abi.encodeCall(operatorStore.hasPermission, (_notOwner, owner, projectId, JBBuybackDelegateOperations.MODIFY_POOL)), 
            abi.encode(false)
        );
        vm.expectCall(
            address(operatorStore),
            abi.encodeCall(operatorStore.hasPermission, (_notOwner, owner, projectId, JBBuybackDelegateOperations.MODIFY_POOL))
        );

        vm.mockCall(
            address(operatorStore),
            abi.encodeCall(operatorStore.hasPermission, (_notOwner, owner, 0, JBBuybackDelegateOperations.MODIFY_POOL)), 
            abi.encode(false)
        );
        vm.expectCall(
            address(operatorStore),
            abi.encodeCall(operatorStore.hasPermission, (_notOwner, owner, 0, JBBuybackDelegateOperations.MODIFY_POOL))
        );

        // check: revert?
        vm.expectRevert(abi.encodeWithSignature("UNAUTHORIZED()"));

        // Test: set the twap
        vm.prank(_notOwner);
        delegate.setTwapDelta(projectId, 1);
    }
}

contract ForTest_JBGenericBuybackDelegate is JBGenericBuybackDelegate {
    constructor(
        IWETH9 _weth,
        address _factory,
        IJBDirectory _directory,
        IJBController3_1 _controller,
        bytes4 _id
    )
        JBGenericBuybackDelegate(
            _weth,
            _factory,
            _directory,
            _controller,
            _id
        )
    {}

    function ForTest_getQuote(uint256 _projectId, IJBPaymentTerminal _terminal, address _projectToken, uint256 _amountIn) external view returns (uint256 _amountOut) {
        return _getQuote( _projectId,  _terminal,  _projectToken,  _amountIn);
    }

    function ForTest_initPool(IUniswapV3Pool _pool, uint256 _projectId, uint32 _secondsAgo, uint256 _twapDelta, address _projectToken, address _terminalToken) external{
        secondsAgoOf[_projectId] = _secondsAgo;
        twapDeltaOf[_projectId] = _twapDelta;
        projectTokenOf[_projectId] = _projectToken;
        poolOf[_projectId][_terminalToken] = _pool;
    }
}
