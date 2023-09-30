// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import "forge-std/Test.sol";

import "@jbx-protocol/juice-contracts-v3/contracts/JBController3_1.sol";
import "@jbx-protocol/juice-contracts-v3/contracts/JBDirectory.sol";
import "@jbx-protocol/juice-contracts-v3/contracts/JBETHPaymentTerminal3_1_1.sol";
import "@jbx-protocol/juice-contracts-v3/contracts/JBFundAccessConstraintsStore.sol";
import "@jbx-protocol/juice-contracts-v3/contracts/JBSingleTokenPaymentTerminalStore3_1_1.sol";
import "@jbx-protocol/juice-contracts-v3/contracts/JBFundingCycleStore.sol";
import "@jbx-protocol/juice-contracts-v3/contracts/JBOperatorStore.sol";
import "@jbx-protocol/juice-contracts-v3/contracts/JBPrices.sol";
import "@jbx-protocol/juice-contracts-v3/contracts/JBProjects.sol";
import "@jbx-protocol/juice-contracts-v3/contracts/JBSplitsStore.sol";
import "@jbx-protocol/juice-contracts-v3/contracts/JBTokenStore.sol";

import "@jbx-protocol/juice-contracts-v3/contracts/structs/JBDidPayData.sol";
import "@jbx-protocol/juice-contracts-v3/contracts/structs/JBDidRedeemData.sol";
import "@jbx-protocol/juice-contracts-v3/contracts/structs/JBFee.sol";
import "@jbx-protocol/juice-contracts-v3/contracts/structs/JBFundAccessConstraints.sol";
import "@jbx-protocol/juice-contracts-v3/contracts/structs/JBFundingCycle.sol";
import "@jbx-protocol/juice-contracts-v3/contracts/structs/JBFundingCycleData.sol";
import "@jbx-protocol/juice-contracts-v3/contracts/structs/JBFundingCycleMetadata.sol";
import "@jbx-protocol/juice-contracts-v3/contracts/structs/JBGroupedSplits.sol";
import "@jbx-protocol/juice-contracts-v3/contracts/structs/JBOperatorData.sol";
import "@jbx-protocol/juice-contracts-v3/contracts/structs/JBPayParamsData.sol";
import "@jbx-protocol/juice-contracts-v3/contracts/structs/JBProjectMetadata.sol";
import "@jbx-protocol/juice-contracts-v3/contracts/structs/JBRedeemParamsData.sol";
import "@jbx-protocol/juice-contracts-v3/contracts/structs/JBSplit.sol";
import "@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBPaymentTerminal.sol";
import "@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBToken.sol";
import "@jbx-protocol/juice-contracts-v3/contracts/libraries/JBConstants.sol";

import "@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBSingleTokenPaymentTerminalStore.sol";

import "@paulrberg/contracts/math/PRBMath.sol";

import "./AccessJBLib.sol";
import "../../interfaces/external/IWETH9.sol";
import "../../JBBuybackDelegate.sol";



// Base contract for Juicebox system tests.
//
// Provides common functionality, such as deploying contracts on test setup for v3.
contract TestBaseWorkflowV3 is Test {
    using stdStorage for StdStorage;

    //*********************************************************************//
    // -------------------- internal stored properties ------------------- //
    //*********************************************************************//

    // Multisig address used for testing.
    address internal _multisig = makeAddr('mooltichig');
    address internal _beneficiary = makeAddr('benefishary');

    JBOperatorStore internal _jbOperatorStore;
    JBProjects internal _jbProjects;
    JBPrices internal _jbPrices;
    JBDirectory internal _jbDirectory;
    JBFundAccessConstraintsStore internal _fundAccessConstraintsStore;
    JBFundingCycleStore internal _jbFundingCycleStore;
    JBTokenStore internal _jbTokenStore;
    JBSplitsStore internal _jbSplitsStore;
    JBController3_1 internal _jbController;
    JBSingleTokenPaymentTerminalStore3_1_1 internal _jbPaymentTerminalStore;
    JBETHPaymentTerminal3_1_1 internal _jbETHPaymentTerminal;
    AccessJBLib internal _accessJBLib;

    JBBuybackDelegate _delegate;

    uint256 _projectId;
    uint256 reservedRate = 4500;
    uint256 weight = 10 ether ; // Minting 10 token per eth
    uint32 cardinality = 1000;
    uint256 twapDelta = 500;

    JBProjectMetadata _projectMetadata;
    JBFundingCycleData _data;
    JBFundingCycleData _dataReconfiguration;
    JBFundingCycleData _dataWithoutBallot;
    JBFundingCycleMetadata _metadata;
    JBFundAccessConstraints[] _fundAccessConstraints; // Default empty
    IJBPaymentTerminal[] _terminals; // Default empty

    // Use the L1 UniswapV3Pool jbx/eth 1% fee for create2 magic
    // IUniswapV3Pool pool = IUniswapV3Pool(0x48598Ff1Cee7b4d31f8f9050C2bbAE98e17E6b17);
    IJBToken jbx = IJBToken(0x3abF2A4f8452cCC2CF7b4C1e4663147600646f66);
    IWETH9 weth = IWETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    address _uniswapFactory = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    uint24 fee = 10000;

    IUniswapV3Pool pool;


    //*********************************************************************//
    // ------------------------- internal views -------------------------- //
    //*********************************************************************//

    function jbLibraries() internal view returns (AccessJBLib) {
        return _accessJBLib;
    }

    //*********************************************************************//
    // --------------------------- test setup ---------------------------- //
    //*********************************************************************//

    // Deploys and initializes contracts for testing.
    function setUp() public virtual {
        // Labels
        vm.label(_multisig, "projectOwner");
        vm.label(_beneficiary, "beneficiary");
        vm.label(address(pool), "uniswapPool");
        vm.label(address(_uniswapFactory), "uniswapFactory");
        vm.label(address(weth), "$WETH");
        vm.label(address(jbx), "$JBX");

        // mock
        vm.etch(address(pool), "0x69");
        vm.etch(address(weth), "0x69");

        // JBOperatorStore
        _jbOperatorStore = new JBOperatorStore();
        vm.label(address(_jbOperatorStore), "JBOperatorStore");

        // JBProjects
        _jbProjects = new JBProjects(_jbOperatorStore);
        vm.label(address(_jbProjects), "JBProjects");

        // JBPrices
        _jbPrices = new JBPrices(_multisig);
        vm.label(address(_jbPrices), "JBPrices");

        address contractAtNoncePlusOne = computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);

        // JBFundingCycleStore
        _jbFundingCycleStore = new JBFundingCycleStore(IJBDirectory(contractAtNoncePlusOne));
        vm.label(address(_jbFundingCycleStore), "JBFundingCycleStore");

        // JBDirectory
        _jbDirectory = new JBDirectory(_jbOperatorStore, _jbProjects, _jbFundingCycleStore, _multisig);
        vm.label(address(_jbDirectory), "JBDirectory");

        // JBTokenStore
        _jbTokenStore = new JBTokenStore(_jbOperatorStore, _jbProjects, _jbDirectory, _jbFundingCycleStore);
        vm.label(address(_jbTokenStore), "JBTokenStore");

        // JBSplitsStore
        _jbSplitsStore = new JBSplitsStore(_jbOperatorStore, _jbProjects, _jbDirectory);
        vm.label(address(_jbSplitsStore), "JBSplitsStore");

        _fundAccessConstraintsStore = new JBFundAccessConstraintsStore(_jbDirectory);
        vm.label(address(_fundAccessConstraintsStore), "JBFundAccessConstraintsStore");

        // JBController
        _jbController = new JBController3_1(
            _jbOperatorStore,
            _jbProjects,
            _jbDirectory,
            _jbFundingCycleStore,
            _jbTokenStore,
            _jbSplitsStore,
            _fundAccessConstraintsStore
        );
        vm.label(address(_jbController), "JBController");

        vm.prank(_multisig);
        _jbDirectory.setIsAllowedToSetFirstController(address(_jbController), true);

        // JBETHPaymentTerminalStore
        _jbPaymentTerminalStore = new JBSingleTokenPaymentTerminalStore3_1_1(
            _jbDirectory,
            _jbFundingCycleStore,
            _jbPrices
        );
        vm.label(address(_jbPaymentTerminalStore), "JBSingleTokenPaymentTerminalStore");

        // AccessJBLib
        _accessJBLib = new AccessJBLib();

        // JBETHPaymentTerminal
        _jbETHPaymentTerminal = new JBETHPaymentTerminal3_1_1(
            _accessJBLib.ETH(),
            _jbOperatorStore,
            _jbProjects,
            _jbDirectory,
            _jbSplitsStore,
            _jbPrices,
            address(_jbPaymentTerminalStore),
            _multisig
        );
        vm.label(address(_jbETHPaymentTerminal), "JBETHPaymentTerminal");

        // Deploy the delegate
        _delegate = new JBBuybackDelegate({
            _weth: weth,
            _factory: _uniswapFactory,
            _directory: IJBDirectory(address(_jbDirectory)),
            _controller: _jbController,
            _delegateId: bytes4(hex'69')
        });

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

        vm.prank(_multisig);
        _jbTokenStore.issueFor(_projectId, "jbx", "jbx");

        vm.prank(_multisig);
        pool = _delegate.setPoolFor(_projectId, fee, uint32(cardinality), twapDelta, address(weth));

    }
}
