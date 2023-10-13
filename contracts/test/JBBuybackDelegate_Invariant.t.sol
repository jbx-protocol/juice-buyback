// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import "./helpers/TestBaseWorkflowV3.sol";

import {JBTokens} from "@jbx-protocol/juice-contracts-v3/contracts/libraries/JBTokens.sol";
import {JBDelegateMetadataHelper} from "@jbx-protocol/juice-delegate-metadata-lib/src/JBDelegateMetadataHelper.sol";
import {PoolTestHelper} from "@exhausted-pigeon/uniswap-v3-foundry-pool/src/PoolTestHelper.sol";


/**
 * @notice Invariant tests for the JBBuybackDelegate contract.
 *
 * @dev    Invariant tested:
 *          - BBD1: totalSupply after pay == total supply before pay + (amountIn * weight / 10^18)
 */
contract TestJBBuybackDelegate_Invariant is TestBaseWorkflowV3, PoolTestHelper {

    BBDHandler handler;
    JBDelegateMetadataHelper _metadataHelper = new JBDelegateMetadataHelper();

    /**
     * @notice Set up a new JBX project and use the buyback delegate as the datasource
     */
    function setUp() public override {
        // super is the Jbx V3 fixture: deploy full protocol, launch project 1, emit token, deploy delegate, set the pool
        super.setUp();

        handler = new BBDHandler(_jbETHPaymentTerminal, _projectId, pool, _delegate);

        PoolTestHelper _helper = new PoolTestHelper();
        IUniswapV3Pool _newPool = IUniswapV3Pool(address(_helper.createPool(address(weth), address(_jbController.tokenStore().tokenOf(_projectId)), fee, 1000 ether, PoolTestHelper.Chains.Mainnet)));

        targetContract(address(handler));
    }

    function invariant_BBD1() public {
        uint256 _amountIn = handler.ghost_accumulatorAmountIn();

        assertEq(
            _jbController.totalOutstandingTokensOf(_projectId),
            _amountIn * weight / 10 ** 18
        );
    }

    function test_inv() public {
        assert(true);
    }
}

contract BBDHandler is Test {
    JBDelegateMetadataHelper immutable metadataHelper;
    JBETHPaymentTerminal3_1_1 immutable jbETHPaymentTerminal;
    IUniswapV3Pool immutable pool;
    IJBBuybackDelegate immutable delegate;
    uint256 immutable projectId;

    address public _beneficiary;

    uint256 public ghost_accumulatorAmountIn;
    uint256 public ghost_liquidityProvided;
    uint256 public ghost_liquidityToUse;
    
    modifier useLiquidity(uint256 _seed) {
        ghost_liquidityToUse = bound(_seed, 1, ghost_liquidityProvided);
        _;
    }

    constructor(
        JBETHPaymentTerminal3_1_1 _terminal, 
        uint256 _projectId, 
        IUniswapV3Pool _pool,
        IJBBuybackDelegate _delegate
    ) {
        metadataHelper = new JBDelegateMetadataHelper();

        jbETHPaymentTerminal = _terminal;
        projectId = _projectId;
        pool = _pool;
        delegate = _delegate;

        _beneficiary = makeAddr('_beneficiary');
    }

    function trigger_pay(uint256 _amountIn) public {
        _amountIn = bound(_amountIn, 0, 10000 ether);

        // bool zeroForOne = jbETHPaymentTerminal.token() > address(JBTokens.ETH);

        // vm.mockCall(
        //     address(pool),
        //     abi.encodeCall(
        //         IUniswapV3PoolActions.swap,
        //         (
        //             address(delegate),
        //             zeroForOne,
        //             int256(_amountIn),
        //             zeroForOne
        //                 ? TickMath.MIN_SQRT_RATIO + 1
        //                 : TickMath.MAX_SQRT_RATIO - 1,
        //             abi.encode(projectId, JBTokens.ETH)
        //         )
        //     ),
        //     abi.encode(0, 0)
        // );

        vm.deal(address(this), _amountIn);
        ghost_accumulatorAmountIn += _amountIn;

        uint256 _quote = 1;

        // set only valid metadata
        bytes[] memory _quoteData = new bytes[](1);
        _quoteData[0] = abi.encode(_amountIn, _quote);

        // Pass the delegate id
        bytes4[] memory _ids = new bytes4[](1);
        _ids[0] = bytes4(hex"69");

        // Generate the metadata
        bytes memory _delegateMetadata = metadataHelper.createMetadata(_ids, _quoteData);

        jbETHPaymentTerminal.pay{value: _amountIn}(
            projectId,
            _amountIn,
            address(0),
            _beneficiary,
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

    function addLiquidity(uint256 _amount0, uint256 _amount1, int24 _lowerTick, int24 _upperTick) public {
        // ghost_liquidityProvided += pool.addLiquidity()
        
    }

}
