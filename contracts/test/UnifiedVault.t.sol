// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {UnifiedVault} from "../src/UnifiedVault.sol";
import {Client} from "@chainlink/contracts/libraries/Client.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockRouter} from "./mocks/MockRouter.sol";

contract UnifiedVaultTest is Test {
    MockERC20 internal link;
    MockERC20 internal token;
    MockRouter internal router;
    UnifiedVault internal vault;

    address internal user = address(0x1001);
    address internal forwarder = address(0x2002);
    address internal receiver = address(0x3003);

    uint64 internal destinationChainSelector = 16015286601757825753;

    function setUp() public {
        link = new MockERC20("Chainlink", "LINK", 18);
        token = new MockERC20("Token", "TKN", 18);
        router = new MockRouter();
        vault = new UnifiedVault(address(router), address(link));

        vault.setCCIPReceiver(receiver);
        vault.setCREForwarder(forwarder);
    }

    function testRequestDepositTransfersAndCredits() public {
        uint256 amount = 1e18;

        token.mint(user, amount);
        vm.prank(user);
        token.approve(address(vault), amount);

        vm.prank(user);
        vault.requestDeposit(address(token), amount, destinationChainSelector);

        assertEq(vault.balances(user, address(token)), amount);
        assertEq(token.balanceOf(address(vault)), amount);
    }

    function testRequestDepositRevertsOnZero() public {
        vm.expectRevert(UnifiedVault.UnifiedVault__InvalidAmount.selector);
        vault.requestDeposit(address(token), 0, destinationChainSelector);
    }

    function testRequestWithdrawRevertsOnInsufficientBalance() public {
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(UnifiedVault.UnifiedVault__InsufficientBalance.selector, address(token), 0, 1e18)
        );
        vault.requestWithdraw(address(token), 1e18, destinationChainSelector);
    }

    function testRequestWithdrawDebitsBalance() public {
        uint256 amount = 1e18;
        token.mint(user, amount);
        vm.prank(user);
        token.approve(address(vault), amount);
        vm.prank(user);
        vault.requestDeposit(address(token), amount, destinationChainSelector);

        vm.prank(user);
        vault.requestWithdraw(address(token), amount, destinationChainSelector);

        assertEq(vault.balances(user, address(token)), 0);
    }

    function testExecuteCCIPSendRevertsForUnauthorized() public {
        Client.EVM2AnyMessage memory message = _buildMessage(address(token), 1e18);
        vm.prank(user);
        vm.expectRevert(UnifiedVault.UnifiedVault__Unauthorized.selector);
        vault.executeCCIPSend(destinationChainSelector, message);
    }

    function testExecuteCCIPSendRevertsOnInsufficientLink() public {
        Client.EVM2AnyMessage memory message = _buildMessage(address(token), 1e18);
        router.setFee(2e18);
        link.mint(address(vault), 1e18);

        vm.prank(forwarder);
        vm.expectRevert(abi.encodeWithSelector(UnifiedVault.UnifiedVault__InsufficientLINK.selector, 1e18, 2e18));
        vault.executeCCIPSend(destinationChainSelector, message);
    }

    function testExecuteCCIPSendApprovesAndTransfers() public {
        uint256 fee = 0.5e18;
        uint256 amount = 1e18;

        router.setFee(fee);
        link.mint(address(vault), 5e18);
        token.mint(address(vault), amount);

        Client.EVM2AnyMessage memory message = _buildMessage(address(token), amount);

        vm.prank(forwarder);
        vault.executeCCIPSend(destinationChainSelector, message);

        assertEq(router.lastDestinationChainSelector(), destinationChainSelector);
        assertEq(router.lastFeeToken(), address(link));
        assertEq(link.balanceOf(address(router)), fee);
        assertEq(token.balanceOf(address(router)), amount);
    }

    function testOnReportExecutes() public {
        uint256 fee = 0.2e18;
        uint256 amount = 2e18;

        router.setFee(fee);
        link.mint(address(vault), 5e18);
        token.mint(address(vault), amount);

        Client.EVM2AnyMessage memory message = _buildMessage(address(token), amount);
        bytes memory report = abi.encodeWithSelector(vault.executeCCIPSend.selector, destinationChainSelector, message);

        vm.prank(forwarder);
        vault.onReport(hex"", report);

        assertEq(link.balanceOf(address(router)), fee);
        assertEq(token.balanceOf(address(router)), amount);
    }

    function testOnReportRevertsForInvalidSelector() public {
        Client.EVM2AnyMessage memory message = _buildMessage(address(token), 1e18);
        bytes memory report = abi.encodeWithSelector(bytes4(0xdeadbeef), destinationChainSelector, message);

        vm.prank(forwarder);
        vm.expectRevert(UnifiedVault.UnifiedVault__InvalidReport.selector);
        vault.onReport(hex"", report);
    }

    function testOnReportRevertsForUnauthorized() public {
        Client.EVM2AnyMessage memory message = _buildMessage(address(token), 1e18);
        bytes memory report = abi.encodeWithSelector(vault.executeCCIPSend.selector, destinationChainSelector, message);

        vm.prank(user);
        vm.expectRevert(UnifiedVault.UnifiedVault__Unauthorized.selector);
        vault.onReport(hex"", report);
    }

    function _buildMessage(address tokenAddress, uint256 amount) internal view returns (Client.EVM2AnyMessage memory) {
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({token: tokenAddress, amount: amount});

        return Client.EVM2AnyMessage({
            receiver: abi.encode(address(0xBEEF)),
            data: abi.encode("DEPOSIT", abi.encode(user)),
            tokenAmounts: tokenAmounts,
            feeToken: address(link),
            extraArgs: ""
        });
    }
}
