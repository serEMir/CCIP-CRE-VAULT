// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Client} from "@chainlink/contracts/libraries/Client.sol";
import {VaultCCIPReceiver} from "../../src/VaultCCIPReceiver.sol";

contract TestVaultCCIPReceiver is VaultCCIPReceiver {
    constructor(address router, address vault) VaultCCIPReceiver(router, vault) {}

    function exposedCcipReceive(Client.Any2EVMMessage memory message) external {
        _ccipReceive(message);
    }
}
