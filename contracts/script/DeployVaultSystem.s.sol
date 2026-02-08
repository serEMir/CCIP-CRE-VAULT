// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Script, console} from "forge-std/Script.sol";
import {UnifiedVault} from "../src/UnifiedVault.sol";
import {VaultCCIPReceiver} from "../src/VaultCCIPReceiver.sol";

contract DeployVaultSystem is Script {
    // CRE operator address
    address constant CRE_OPERATOR = 0x4a1a5E53A4d704077F945006953dA128C1297425;
    // CRE forwarder (Keystone Forwarder) address
    address constant CRE_FORWARDER = 0x82300bd7c3958625581cc2F77bC6464dcEcDF3e5;

    // Sepolia testnet config
    address constant SEPOLIA_ROUTER = 0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59;
    address constant SEPOLIA_LINK = 0x779877A7B0D9E8603169DdbD7836e478b4624789;
    uint64 constant SEPOLIA_CHAIN_SELECTOR = 16015286601757825753;

    // Base Sepolia testnet config
    address constant BASE_SEPOLIA_ROUTER = 0xD3b06cEbF099CE7DA4AcCf578aaebFDBd6e88a93;
    address constant BASE_SEPOLIA_LINK = 0xE4aB69C077896252FAFBD49EFD26B5D171A32410;
    uint64 constant BASE_SEPOLIA_CHAIN_SELECTOR = 10344971235874465080;

    function run() external {
        (address router, address link, address creOperator, uint64 chainSelector) = getChainConfig();
        console.log("Deploying UnifiedVault on chainId:", block.chainid);

        vm.startBroadcast();
        UnifiedVault vault = new UnifiedVault(router, link);
        console.log("UnifiedVault deployed at:", address(vault));

        VaultCCIPReceiver receiver = new VaultCCIPReceiver(router, address(vault));
        console.log("VaultCCIPReceiver deployed at:", address(receiver));

        vault.setCCIPReceiver(address(receiver));
        vault.setCREForwarder(CRE_FORWARDER);
        receiver.allowlistSourceChain(chainSelector, true);

        vault.transferOwnership(creOperator);

        console.log("CRE must call vault.acceptOwnership() to complete transfer");
        vm.stopBroadcast();

        console.log("\n=== DEPLOYMENT COMPLETE ===");
        console.log("Vault:", address(vault));
        console.log("Receiver:", address(receiver));
        console.log("Owner (pending):", creOperator);
    }

    function getChainConfig()
        internal
        view
        returns (address router, address link, address creOperator, uint64 chainSelector)
    {
        if (block.chainid == 11155111) {
            return (SEPOLIA_ROUTER, SEPOLIA_LINK, CRE_OPERATOR, BASE_SEPOLIA_CHAIN_SELECTOR);
        } else if (block.chainid == 84532) {
            return (BASE_SEPOLIA_ROUTER, BASE_SEPOLIA_LINK, CRE_OPERATOR, SEPOLIA_CHAIN_SELECTOR);
        } else {
            revert("Unsupported chain");
        }
    }
}
