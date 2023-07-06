// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../src/EntryPoint.sol";
import "../src/SimpleAccountFactory.sol";

contract SimpleAccountFactoryScript is Script {
    function setUp() public {

    }

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        address payable epAddress = payable(0x3537eD464423B7Fbf509dF88da78Dc86f113A465);
        EntryPoint ep = EntryPoint(epAddress);

        new SimpleAccountFactory{salt: bytes32(uint256(3))}(ep);

        vm.stopBroadcast();
    }
}
