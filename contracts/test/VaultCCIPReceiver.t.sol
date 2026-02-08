// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {Client} from "@chainlink/contracts/libraries/Client.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockVault} from "./mocks/MockVault.sol";
import {TestVaultCCIPReceiver} from "./mocks/TestVaultCCIPReceiver.sol";
import {VaultCCIPReceiver} from "../src/VaultCCIPReceiver.sol";

contract VaultCCIPReceiverTest is Test {
    MockERC20 internal token;
    MockVault internal vault;
    TestVaultCCIPReceiver internal receiver;

    uint64 internal sourceChainSelector = 10344971235874465080;
    address internal sourceVault = address(0x9009);
    address internal user = address(0xBEEF);

    function setUp() public {
        token = new MockERC20("Token", "TKN", 18);
        vault = new MockVault();
        receiver = new TestVaultCCIPReceiver(address(0x1111), address(vault));

        receiver.allowlistSourceChain(sourceChainSelector, true);
        receiver.allowlistSender(sourceVault, true);
    }

    function testDepositCreditsUserAndTransfersToken() public {
        uint256 amount = 1e18;
        token.mint(address(receiver), amount);

        Client.EVMTokenAmount[] memory destTokenAmounts = new Client.EVMTokenAmount[](1);
        destTokenAmounts[0] = Client.EVMTokenAmount({token: address(token), amount: amount});

        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: bytes32("msg"),
            sourceChainSelector: sourceChainSelector,
            sender: abi.encode(sourceVault),
            data: abi.encode("DEPOSIT", abi.encode(user)),
            destTokenAmounts: destTokenAmounts
        });

        receiver.exposedCcipReceive(message);

        assertEq(token.balanceOf(address(vault)), amount);
        assertEq(vault.lastCreditUser(), user);
        assertEq(vault.lastCreditToken(), address(token));
        assertEq(vault.lastCreditAmount(), amount);
    }

    function testWithdrawInvokesVault() public {
        uint256 amount = 5e18;
        uint64 targetChainSelector = 16015286601757825753;

        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: bytes32("msg"),
            sourceChainSelector: sourceChainSelector,
            sender: abi.encode(sourceVault),
            data: abi.encode("WITHDRAW", abi.encode(user, address(token), amount, targetChainSelector)),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        receiver.exposedCcipReceive(message);

        assertEq(vault.lastWithdrawUser(), user);
        assertEq(vault.lastWithdrawToken(), address(token));
        assertEq(vault.lastWithdrawAmount(), amount);
        assertEq(vault.lastWithdrawTargetChainSelector(), targetChainSelector);
    }

    function testRevertWhenSourceChainNotAllowlisted() public {
        receiver.allowlistSourceChain(sourceChainSelector, false);

        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: bytes32("msg"),
            sourceChainSelector: sourceChainSelector,
            sender: abi.encode(sourceVault),
            data: abi.encode("DEPOSIT", abi.encode(user)),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        vm.expectRevert(abi.encodeWithSelector(VaultCCIPReceiver.SourceChainNotAllowed.selector, sourceChainSelector));
        receiver.exposedCcipReceive(message);
    }

    function testRevertWhenSenderNotAllowlisted() public {
        receiver.allowlistSender(sourceVault, false);

        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: bytes32("msg"),
            sourceChainSelector: sourceChainSelector,
            sender: abi.encode(sourceVault),
            data: abi.encode("DEPOSIT", abi.encode(user)),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        vm.expectRevert(abi.encodeWithSelector(VaultCCIPReceiver.SenderNotAllowed.selector, sourceVault));
        receiver.exposedCcipReceive(message);
    }

    function testRevertOnInvalidOperation() public {
        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: bytes32("msg"),
            sourceChainSelector: sourceChainSelector,
            sender: abi.encode(sourceVault),
            data: abi.encode("INVALID", abi.encode(user)),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        vm.expectRevert(abi.encodeWithSelector(VaultCCIPReceiver.InvalidOperation.selector, "INVALID"));
        receiver.exposedCcipReceive(message);
    }
}
