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

import "./AccessJBLib.sol";

import "@paulrberg/contracts/math/PRBMath.sol";

// Base contract for Juicebox system tests.
//
// Provides common functionality, such as deploying contracts on test setup for v3.
contract TestBaseWorkflowV3 is Test {
    //*********************************************************************//
    // -------------------- internal stored properties ------------------- //
    //*********************************************************************//

    // Multisig address used for testing.
    address internal _multisig = address(123);
    address internal _beneficiary = address(69420);

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

        // JBOperatorStore
        _jbOperatorStore = new JBOperatorStore();
        vm.label(address(_jbOperatorStore), "JBOperatorStore");

        // JBProjects
        _jbProjects = new JBProjects(_jbOperatorStore);
        vm.label(address(_jbProjects), "JBProjects");

        // JBPrices
        _jbPrices = new JBPrices(_multisig);
        vm.label(address(_jbPrices), "JBPrices");

        address contractAtNoncePlusOne = addressFrom(address(this), 5);

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
    }

    //https://ethereum.stackexchange.com/questions/24248/how-to-calculate-an-ethereum-contracts-address-during-its-creation-using-the-so
    function addressFrom(address _origin, uint256 _nonce) internal pure returns (address _address) {
        bytes memory data;
        if (_nonce == 0x00) {
            data = abi.encodePacked(bytes1(0xd6), bytes1(0x94), _origin, bytes1(0x80));
        } else if (_nonce <= 0x7f) {
            data = abi.encodePacked(bytes1(0xd6), bytes1(0x94), _origin, uint8(_nonce));
        } else if (_nonce <= 0xff) {
            data = abi.encodePacked(bytes1(0xd7), bytes1(0x94), _origin, bytes1(0x81), uint8(_nonce));
        } else if (_nonce <= 0xffff) {
            data = abi.encodePacked(bytes1(0xd8), bytes1(0x94), _origin, bytes1(0x82), uint16(_nonce));
        } else if (_nonce <= 0xffffff) {
            data = abi.encodePacked(bytes1(0xd9), bytes1(0x94), _origin, bytes1(0x83), uint24(_nonce));
        } else {
            data = abi.encodePacked(bytes1(0xda), bytes1(0x94), _origin, bytes1(0x84), uint32(_nonce));
        }
        bytes32 hash = keccak256(data);
        assembly {
            mstore(0, hash)
            _address := mload(0)
        }
    }
}
