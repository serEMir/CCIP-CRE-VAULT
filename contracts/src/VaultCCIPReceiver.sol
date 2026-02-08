// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {CCIPReceiver} from "@chainlink/contracts/applications/CCIPReceiver.sol";
import {Client} from "@chainlink/contracts/libraries/Client.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface IUnifiedVault {
    function creditUser(address user, address token, uint256 amount) external;
    function executeWithdraw(address user, address token, uint256 amount, uint64 targetChainSelector) external;
}

/**
 * @author @serEMir
 * @title VaultCCIPReceiver
 * @notice Receives CCIP messages and forwards them to the vault
 * @dev Decodes operation type and calls appropriate vault function
 */
contract VaultCCIPReceiver is CCIPReceiver, Ownable {
    using SafeERC20 for IERC20;

    // ==================== ERRORS ====================

    error SourceChainNotAllowed(uint64 sourceChain);
    error SenderNotAllowed(address sender);
    error InvalidOperation(string operation);
    error VaultNotSet();

    // ==================== STATE VARIABLES ====================

    IUnifiedVault public vault;

    // Allowlisted source chains and senders
    mapping(uint64 => bool) public allowlistedSourceChainSelectors;
    mapping(address => bool) public allowlistedSenders;

    // ==================== EVENTS ====================

    event MessageReceived(
        bytes32 indexed messageId,
        uint64 indexed sourceChainSelector,
        address indexed sender,
        string operation,
        address token,
        uint256 amount
    );

    event VaultSet(address indexed vault);
    event SourceChainAllowlisted(uint64 indexed chainSelector, bool allowed);
    event SenderAllowlisted(address indexed sender, bool allowed);

    // ==================== CONSTRUCTOR ====================

    constructor(address _router, address _vault) CCIPReceiver(_router) Ownable(msg.sender) {
        vault = IUnifiedVault(_vault);
        emit VaultSet(_vault);
    }

    // ==================== ADMIN FUNCTIONS ====================

    function setVault(address _vault) external onlyOwner {
        vault = IUnifiedVault(_vault);
        emit VaultSet(_vault);
    }

    function allowlistSourceChain(uint64 chainSelector, bool allowed) external onlyOwner {
        allowlistedSourceChainSelectors[chainSelector] = allowed;
        emit SourceChainAllowlisted(chainSelector, allowed);
    }

    function allowlistSender(address sender, bool allowed) external onlyOwner {
        allowlistedSenders[sender] = allowed;
        emit SenderAllowlisted(sender, allowed);
    }

    // ==================== CCIP RECEIVE ====================

    /**
     * @notice Called by CCIP when message arrives
     * @dev Validates source, decodes operation, executes on vault
     */
    function _ccipReceive(Client.Any2EVMMessage memory message) internal override {
        // Validate source chain
        if (!allowlistedSourceChainSelectors[message.sourceChainSelector]) {
            revert SourceChainNotAllowed(message.sourceChainSelector);
        }

        // Validate sender
        address sender = abi.decode(message.sender, (address));
        if (!allowlistedSenders[sender]) {
            revert SenderNotAllowed(sender);
        }

        // Decode operation type and parameters
        (string memory operation, bytes memory params) = abi.decode(message.data, (string, bytes));

        // Get tokens if any were sent
        address receivedToken = address(0);
        uint256 receivedAmount = 0;

        if (message.destTokenAmounts.length > 0) {
            receivedToken = message.destTokenAmounts[0].token;
            receivedAmount = message.destTokenAmounts[0].amount;

            // Transfer tokens to vault
            IERC20(receivedToken).safeTransfer(address(vault), receivedAmount);
        }

        // Execute the appropriate operation
        if (keccak256(bytes(operation)) == keccak256(bytes("DEPOSIT"))) {
            // Deposit operation: credit user
            (address user) = abi.decode(params, (address));
            vault.creditUser(user, receivedToken, receivedAmount);
        } else if (keccak256(bytes(operation)) == keccak256(bytes("WITHDRAW"))) {
            // Withdraw operation: execute withdrawal
            (address user, address token, uint256 amount, uint64 targetChainSelector) =
                abi.decode(params, (address, address, uint256, uint64));
            vault.executeWithdraw(user, token, amount, targetChainSelector);
        } else {
            revert InvalidOperation(operation);
        }

        emit MessageReceived(
            message.messageId, message.sourceChainSelector, sender, operation, receivedToken, receivedAmount
        );
    }
}
