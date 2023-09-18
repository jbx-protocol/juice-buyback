// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";

import "../JBBuybackDelegate.sol";

contract DeployGeneric is Script {
    uint256 _chainId = block.chainid;
    string _network;

    IWETH9 constant _wethMainnet = IWETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IWETH9 constant _wethGoerli = IWETH9(0xB4FBF271143F4FBf7B91A5ded31805e42b2208d6);
    IWETH9 constant _wethSepolia = IWETH9(0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9);
    IWETH9 _weth;

    address constant _factoryMainnet = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address constant _factoryGoerli = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address constant _factorySepolia = 0x0227628f3F023bb0B980b67D528571c95c6DaC1c;
    address _factory;

    IJBDirectory _directory;
    IJBController3_1 _controller;

    bytes4 constant _delegateId = bytes4("BUYB");

    function setUp() public {
        if (_chainId == 1) {
            _network = "mainnet";
            _weth = _wethMainnet;
            _factory = _factoryMainnet;
        } else if (_chainId == 5) {
            _network = "goerli";
            _weth = _wethGoerli;
            _factory = _factoryGoerli;
        } else if (_chainId == 1337) {
            _network = "sepolia";
            _weth = _wethSepolia;
            _factory = _factorySepolia;
        } else {
            revert("Invalid RPC / no juice contracts deployed on this network");
        }

        _directory = IJBDirectory(
            stdJson.readAddress(
                vm.readFile(
                    string.concat(
                        "node_modules/@jbx-protocol/juice-contracts-v3/deployments/", _network, "/JBDirectory.json"
                    )
                ),
                ".address"
            )
        );

        _controller = IJBController3_1(
            stdJson.readAddress(
                vm.readFile(
                    string.concat(
                        "node_modules/@jbx-protocol/juice-contracts-v3/deployments/", _network, "/JBController3_1.json"
                    )
                ),
                ".address"
            )
        );
    }

    function run() public {
        console.log(string.concat("Deploying Generic Buyback Delegate on ", _network));
        console.log("WETH:");
        console.log(address(_weth));
        console.log("Factory:");
        console.log(address(_factory));
        console.log("Directory:");
        console.log(address(_directory));
        console.log("Controller:");
        console.log(address(_controller));

        vm.startBroadcast();
        JBBuybackDelegate _delegate = new JBBuybackDelegate(
            _weth,
            _factory,
            _directory,
            _controller,
            _delegateId
        );

        console.log("Delegate deployed at:");
        console.log(address(_delegate));
    }
}
