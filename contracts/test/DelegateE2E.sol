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

contract TestUnitJBXBuybackDelegate {
  using JBFundingCycleMetadataResolver for JBFundingCycle;

  // Contracts needed
  IJBController oldJbController;
  IJBMigratable newJbController;
  IJBDirectory jbDirectory;
  IJBFundingCycleStore jbFundingCycleStore;
  IJBOperatorStore jbOperatorStore;
  IJBPayoutRedemptionPaymentTerminal jbEthTerminal;
  IJBPayoutRedemptionPaymentTerminal3_1 jbEthPaymentTerminal3_1;
  IJBProjects jbProjects;
  IJBSingleTokenPaymentTerminalStore jbTerminalStore;
  IJBSplitsStore jbSplitsStore;
  IJBTokenStore jbTokenStore;

  // Structure needed
  JBProjectMetadata projectMetadata;
  JBFundingCycleData data;
  JBFundingCycleMetadata metadata;
  JBFundAccessConstraints[] fundAccessConstraints;
  IJBPaymentTerminal[] terminals;
  JBGroupedSplits[] groupedSplits;

  JBXBuybackDelegate _delegate;

  function setUp() public override {
    evm.label(address(pool), 'uniswapPool');
    evm.label(address(weth), '$WETH');
    evm.label(address(jbx), '$JBX');

    _delegate = new JBXBuybackDelegate(IERC20(address(jbx)), IERC20(address(weth)), pool, terminal, weth);

    vm.createSelectFork("https://rpc.ankr.com/eth", 16_677_461);

    // Collect the mainnet deployment addresses
    jbEthTerminal = IJBPayoutRedemptionPaymentTerminal(
        stdJson.readAddress(
            vm.readFile("node_modules/@jbx-protocol/juice-contracts-v3/deployments/mainnet/JBETHPaymentTerminal.json"), ".address"
        )
    );
    vm.label(address(jbEthTerminal), "jbEthTerminal");

    jbEthPaymentTerminal3_1 = IJBPayoutRedemptionPaymentTerminal3_1(
        stdJson.readAddress(
            vm.readFile("node_modules/@jbx-protocol/juice-contracts-v3/deployments/mainnet/JBETHPaymentTerminal3_1.json"), ".address"
        )
    );
    vm.label(address(jbEthPaymentTerminal3_1), "jbEthPaymentTerminal3_1");

    oldJbController = IJBController(
        stdJson.readAddress(vm.readFile("node_modules/@jbx-protocol/juice-contracts-v3/deployments/mainnet/JBController.json"), ".address")
    );

    newJbController = IJBMigratable(
        stdJson.readAddress(vm.readFile("node_modules/@jbx-protocol/juice-contracts-v3/deployments/mainnet/JBController3_1.json"), ".address")
    );
    vm.label(address(newJbController), "newJbController");

    jbOperatorStore = IJBOperatorStore(
        stdJson.readAddress(vm.readFile("deployments/mainnet/JBOperatorStore.json"), ".address")
    );
    vm.label(address(jbOperatorStore), "jbOperatorStore");

    jbProjects = oldJbController.projects();
    jbDirectory = oldJbController.directory();
    jbFundingCycleStore = oldJbController.fundingCycleStore();
    jbTokenStore = oldJbController.tokenStore();
    jbSplitsStore = oldJbController.splitsStore();
    jbTerminalStore = jbEthTerminal.store();
  }

  /**
   + @notice If the amount of token returned by minting is greater then by swapping, mint
   */
  function test_mintIfWeightGreatherThanPrice() public {

  }

  /**
   + @notice If the amount of token returned by swapping is greater then by minting, swap
   */
  function test_swapIfQuoteBetter() public {}
}