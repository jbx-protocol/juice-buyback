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
import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol';
import '@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol';
import '@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol';
import '@uniswap/v3-core/contracts/libraries/TickMath.sol';


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

  IUniswapV3Pool pool;
  IWETH9 weth = IWETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
  IERC20 jbx = IERC20(0x4554CC10898f92D45378b98D6D6c2dD54c687Fb2);

  uint256 price = 69420 ether;
  uint160 sqrtPriceX96 = 79228162514264337593543950336000000000;

  function setUp() public {
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

    pool = IUniswapV3Pool(IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984).createPool(address(weth), address(jbx), 100));
    pool.initialize(sqrtPriceX96); // 1 eth <=> 69420 jbx

    vm.startPrank(address(123), address(123));
    deal(address(weth), address(123), 1000 ether);
    deal(address(jbx), address(123), 1000 ether);
    
    // approve:
    address POSITION_MANAGER = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    jbx.approve(POSITION_MANAGER, 1000 ether);
    weth.approve(POSITION_MANAGER, 1000 ether);

    // mint concentrated position 
    INonfungiblePositionManager.MintParams memory params =
            INonfungiblePositionManager.MintParams({
                token0: address(jbx),
                token1: address(weth),
                fee: 100,
                tickLower: TickMath.getTickAtSqrtRatio(sqrtPriceX96) - pool.tickSpacing(),
                tickUpper: TickMath.getTickAtSqrtRatio(sqrtPriceX96) + pool.tickSpacing(),
                amount0Desired: 1000 ether,
                amount1Desired: 1000 ether,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(123),
                deadline: block.timestamp
            });

    INonfungiblePositionManager(POSITION_MANAGER).mint(params);

    vm.stopPrank();

    delegate = new JBXBuybackDelegate(IERC20(address(jbx)), IERC20(address(weth)), pool, jbEthPaymentTerminal, weth);

    vm.label(address(pool), 'uniswapPool');
    vm.label(address(weth), '$WETH');
    vm.label(address(jbx), '$JBX');
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
      true,
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
    // Reconfigure with a weight smaller than the quote
    _reconfigure(1, address(delegate), price - 100, 1);

    // Build the metadata using the quote at that block
    bytes memory _metadata = abi.encode(
        bytes32(0),
        bytes32(0),
        sqrtPriceX96, //quote
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
      true,
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

  function test_mintIfPreferClaimedIsFalse() public {}

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

    // Move to next fc
    vm.warp(block.timestamp + 14 days + 1);
  }
}