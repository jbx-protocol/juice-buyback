// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import '../interfaces/external/IWETH9.sol';
import './helpers/TestBaseWorkflowV3.sol';

import '@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBController3_1.sol';
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

import 'forge-std/Test.sol';

contract TestUnitJBXBuybackDelegate is Test {
  using JBFundingCycleMetadataResolver for JBFundingCycle;

  // Contracts needed
  IJBFundingCycleStore jbFundingCycleStore;
  IJBProjects jbProjects;
  IJBSplitsStore jbSplitsStore;
  IJBPayoutRedemptionPaymentTerminal3_1 jbEthPaymentTerminal;
  IJBSingleTokenPaymentTerminalStore jbTerminalStore;
  IJBController3_1 jbController;
  IJBTokenStore jbTokenStore;

  // Structure needed
  JBProjectMetadata projectMetadata;
  JBFundingCycleData data;
  JBFundingCycleMetadata metadata;
  JBFundAccessConstraints[] fundAccessConstraints;
  IJBPaymentTerminal[] terminals;
  JBGroupedSplits[] groupedSplits;

  JBXBuybackDelegate delegate;

  IUniswapV3Pool pool = IUniswapV3Pool(0x48598Ff1Cee7b4d31f8f9050C2bbAE98e17E6b17);
  IWETH9 weth = IWETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
  IERC20 jbx = IERC20(0x3abF2A4f8452cCC2CF7b4C1e4663147600646f66);

  uint256 price = 845672.4 ether;

  function setUp() public {

    vm.label(address(pool), 'uniswapPool');
    vm.label(address(weth), '$WETH');
    vm.label(address(jbx), '$JBX');

    delegate = new JBXBuybackDelegate(IERC20(address(jbx)), IERC20(address(weth)), pool, jbEthPaymentTerminal, weth);

    // Quote uniV3: 845,672.44 jbx/eth block 17239357
    vm.createSelectFork("https://rpc.ankr.com/eth", 17239357);

    // Collect the mainnet deployment addresses
    jbEthPaymentTerminal = IJBPayoutRedemptionPaymentTerminal3_1(
        stdJson.readAddress(
            vm.readFile("node_modules/@jbx-protocol/juice-contracts-v3/deployments/mainnet/JBETHPaymentTerminal3_1.json"), ".address"
        )
    );
    vm.label(address(jbEthPaymentTerminal), "jbEthPaymentTerminal3_1");

    jbController = IJBController3_1(
        stdJson.readAddress(vm.readFile("node_modules/@jbx-protocol/juice-contracts-v3/deployments/mainnet/JBController3_1.json"), ".address")
    );
    vm.label(address(jbController), "jbController");

    jbTokenStore = jbController.tokenStore();
    jbFundingCycleStore = jbController.fundingCycleStore();
    jbProjects = jbController.projects();
    jbSplitsStore = jbController.splitsStore();
  }

  /**
   * @notice If the amount of token returned by minting is greater than by swapping, mint
   *
   * @dev    Should mint for both beneficiary and reserve
   */
  function test_mintIfWeightGreatherThanPrice() public {
    // Reconfigure with a weight bigger than the quote
    _reconfigure(1, address(delegate), price + 1, 0);

    // Build the metadata using the quote at that block
    bytes memory _metadata = abi.encode(
        bytes32(0),
        bytes32(0),
        price, //quote
        1 //slippage
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
      false,
      /* _memo */
      'Take my money!',
      /* _delegateMetadata */
      _metadata
    );

    // Check: token minted

    // Check: event for mint

  }

  /**
   * @notice If the amount of token returned by swapping is greater than by minting, swap
   *
   * @dev    Should swap for both beneficiary and reserve (by burning/minting)
   */
  function test_swapIfQuoteBetter() public {
        // Reconfigure with a weight bigger than the quote
    _reconfigure(1, address(delegate), price - 1, 0);

    // Build the metadata using the quote at that block
    bytes memory _metadata = abi.encode(
        bytes32(0),
        bytes32(0),
        price, //quote
        1 //slippage
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
      false,
      /* _memo */
      'Take my money!',
      /* _delegateMetadata */
      _metadata
    );
  }

  /**
   * @notice If the amount of token returned by swapping is greater than by minting but slippage is too high, mint
   */
  function test_mintIfSlippageTooHigh() public {}

  function _reconfigure(uint256 _projectId, address _delegate, uint256 _weight, uint256 _reservedRate) internal {
    address _projectOwner = jbProjects.ownerOf(_projectId);

    JBFundingCycle memory _fundingCycle = jbFundingCycleStore.currentOf(_projectId);
    metadata = _fundingCycle.expandMetadata();

    JBGroupedSplits[] memory _groupedSplits = new JBGroupedSplits[](1);
    _groupedSplits[0] = JBGroupedSplits({
        group: 1,
        splits: jbSplitsStore.splitsOf(
            _projectId,
            _fundingCycle.configuration, /*domain*/
            JBSplitsGroups.ETH_PAYOUT /*group*/)
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
  }
}