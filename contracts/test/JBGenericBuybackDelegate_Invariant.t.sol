// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

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

import {JBDelegateMetadataHelper} from "@jbx-protocol/juice-delegate-metadata-lib/src/JBDelegateMetadataHelper.sol";

import "@paulrberg/contracts/math/PRBMath.sol";
import "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";

import "../mock/MockAllocator.sol";

/**
 * @notice Invariant tests for the JBBuybackDelegate contract.
 *
 * @dev    Invariant tested:
 *          - BBD1: totalSupply after pay == total supply before pay + (amountIn * weight / 10^18)
 *
 */
contract TestJBGenericBuybackDelegate_Invariant is TestBaseWorkflowV3 {
    BBDHandler handler;
    JBDelegateMetadataHelper _metadataHelper = new JBDelegateMetadataHelper();

    /**
     * @notice Set up a new JBX project and use the buyback delegate as the datasource
     */
    function setUp() public override {
        // super is the Jbx V3 fixture: deploy full protocol, launch project 1, emit token, deploy delegate, set the pool
        super.setUp();

        handler = new BBDHandler(_jbETHPaymentTerminal, _projectId, pool, _delegate);

        targetContract(address(handler));

        // for(uint256 i; i < targetContracts().length; i++)
        //     console.log(targetContracts()[i]);

        // if(excludeContracts().length == 0) console.log("no exclude");

        // else for(uint256 i; i < excludeContracts().length; i++)
        //     console.log(excludeContracts()[i]);
    }

    function invariant_BBD1() public {
        uint256 _amountIn = handler.ghost_accumulatorAmountIn();

        assertEq(
            _jbController.totalOutstandingTokensOf(_projectId),
            _amountIn * weight / 10 ** 18
        );
    }
}

contract BBDHandler is Test {
    JBDelegateMetadataHelper immutable metadataHelper;
    JBETHPaymentTerminal3_1_1 immutable jbETHPaymentTerminal;
    IUniswapV3Pool immutable pool;
    IJBGenericBuybackDelegate immutable delegate;
    uint256 immutable projectId;

    uint256 public ghost_accumulatorAmountIn;
    address public _beneficiary;

    constructor(
        JBETHPaymentTerminal3_1_1 _terminal, 
        uint256 _projectId, 
        IUniswapV3Pool _pool,
        IJBGenericBuybackDelegate _delegate
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

        bool zeroForOne = jbETHPaymentTerminal.token() > address(JBTokens.ETH);

        vm.mockCall(
            address(pool),
            abi.encodeCall(
                IUniswapV3PoolActions.swap,
                (
                    address(delegate),
                    zeroForOne,
                    int256(_amountIn),
                    zeroForOne
                        ? TickMath.MIN_SQRT_RATIO + 1
                        : TickMath.MAX_SQRT_RATIO - 1,
                    abi.encode(projectId, JBTokens.ETH)
                )
            ),
            abi.encode(0, 0)
        );

        vm.deal(address(this), _amountIn);
        ghost_accumulatorAmountIn += _amountIn;

        uint256 _quote = 1;

        // set only valid metadata
        bytes[] memory _quoteData = new bytes[](1);
        _quoteData[0] = abi.encode(_quote, _amountIn);

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

    function _mockPoolState(address _pool) internal {

    }

}
