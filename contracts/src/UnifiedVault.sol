// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {IRouterClient} from "@chainlink/contracts/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts/libraries/Client.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @author @serEMir
 * @title UnifiedVault
 * @notice CRE-powered cross-chain vault that works bidirectionally
 * @dev Owner (CRE operator) can be changed via two-step process for safety
 */
contract UnifiedVault is Ownable2Step {
    using SafeERC20 for IERC20;
    using Client for Client.EVM2AnyMessage;

    // ==================== ERRORS ====================

    error UnifiedVault__InvalidAmount();
    error UnifiedVault__InsufficientBalance(address token, uint256 available, uint256 required);
    error UnifiedVault__InsufficientLINK(uint256 available, uint256 required);
    error UnifiedVault__Unauthorized();
    error UnifiedVault__InvalidReport();

    // ==================== STATE VARIABLES ====================

    IRouterClient public immutable router;
    IERC20 public immutable linkToken;
    address public ccipReceiver;
    address public creForwarder;

    mapping(address user => mapping(address token => uint256 amount)) public balances;

    // ==================== EVENTS ====================

    event DepositRequested(address indexed user, address indexed token, uint256 amount, uint64 targetChainSelector);

    event WithdrawRequested(address indexed user, address indexed token, uint256 amount, uint64 targetChainSelector);

    event WithdrawExecutionRequested(
        address indexed user, address indexed token, uint256 amount, uint64 targetChainSelector
    );

    event CCIPMessageSent(bytes32 indexed messageId, uint64 indexed destinationChainSelector);

    event CCIPReceiverSet(address indexed receiver);
    event CREForwarderSet(address indexed forwarder);

    // ==================== MODIFIERS ====================

    modifier onlyReceiverOrOwner() {
        if (msg.sender != ccipReceiver && msg.sender != owner()) {
            revert UnifiedVault__Unauthorized();
        }
        _;
    }

    modifier onlyOwnerOrForwarder() {
        if (msg.sender != owner() && msg.sender != creForwarder) {
            revert UnifiedVault__Unauthorized();
        }
        _;
    }

    // ==================== CONSTRUCTOR ====================

    constructor(address _router, address _linkToken) Ownable(msg.sender) {
        router = IRouterClient(_router);
        linkToken = IERC20(_linkToken);
    }

    // ==================== ADMIN FUNCTIONS ====================

    /**
     * @notice Set the authorized CCIP receiver contract
     * @param _receiver Address of the VaultCCIPReceiver contract
     */
    function setCCIPReceiver(address _receiver) external onlyOwner {
        ccipReceiver = _receiver;
        emit CCIPReceiverSet(_receiver);
    }

    /**
     * @notice Set the authorized CRE forwarder (Keystone Forwarder) contract
     * @param _forwarder Address of the CRE forwarder contract
     */
    function setCREForwarder(address _forwarder) external onlyOwner {
        creForwarder = _forwarder;
        emit CREForwarderSet(_forwarder);
    }

    /**
     * @notice Emergency function to recover stuck tokens
     * @dev Only owner (initially deployer, then CRE) can call
     */
    function recoverTokens(address token, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(owner(), amount);
    }

    // ==================== USER-FACING FUNCTIONS ====================

    /**
     * @notice User deposits tokens to another chain
     * @dev User stays on this chain, tokens get vaulted on target chain
     * @param token Token address on this chain
     * @param amount Amount to deposit
     * @param targetChainSelector Chain selector where vault will hold tokens
     */
    function requestDeposit(address token, uint256 amount, uint64 targetChainSelector) external {
        if (amount == 0) {
            revert UnifiedVault__InvalidAmount();
        }
        balances[msg.sender][token] += amount;
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // Emit event for CRE orchestration
        emit DepositRequested(msg.sender, token, amount, targetChainSelector);
    }

    /**
     * @notice User requests withdrawal from another chain
     * @dev User stays on this chain, CRE orchestrates cross-chain withdrawal
     * @param token Token address (on the vault chain)
     * @param amount Amount to withdraw
     * @param targetChainSelector Chain selector where the vault holding tokens is located
     */
    function requestWithdraw(address token, uint256 amount, uint64 targetChainSelector) external {
        if (amount == 0) {
            revert UnifiedVault__InvalidAmount();
        }
        if (balances[msg.sender][token] < amount) {
            revert UnifiedVault__InsufficientBalance(token, balances[msg.sender][token], amount);
        }
        balances[msg.sender][token] -= amount;

        // Emit event for CRE orchestration
        emit WithdrawRequested(msg.sender, token, amount, targetChainSelector);
    }

    // ==================== CRE OPERATOR FUNCTIONS ====================

    /**
     * @notice CRE calls this to execute a CCIP send with pre-built message
     * @dev All message construction happens offchain in CRE
     * @param destinationChainSelector CCIP chain selector
     * @param message Pre-built CCIP message from CRE
     * @return messageId CCIP message ID
     */
    function executeCCIPSend(uint64 destinationChainSelector, Client.EVM2AnyMessage memory message)
        external
        onlyOwnerOrForwarder
        returns (bytes32 messageId)
    {
        return _executeCCIPSend(destinationChainSelector, message);
    }

    /**
     * @notice CRE Keystone forwarder entrypoint
     * @dev Expects report bytes to contain executeCCIPSend calldata
     * @param metadata Keystone metadata (unused)
     * @param report Encoded executeCCIPSend calldata
     */
    function onReport(bytes calldata metadata, bytes calldata report) external returns (bytes32 messageId) {
        metadata;
        if (msg.sender != creForwarder) {
            revert UnifiedVault__Unauthorized();
        }
        if (report.length < 4) {
            revert UnifiedVault__InvalidReport();
        }

        bytes4 selector;
        assembly {
            selector := calldataload(report.offset)
        }
        if (selector != this.executeCCIPSend.selector) {
            revert UnifiedVault__InvalidReport();
        }

        (uint64 destinationChainSelector, Client.EVM2AnyMessage memory message) =
            abi.decode(report[4:], (uint64, Client.EVM2AnyMessage));

        return _executeCCIPSend(destinationChainSelector, message);
    }

    function _executeCCIPSend(uint64 destinationChainSelector, Client.EVM2AnyMessage memory message)
        internal
        returns (bytes32 messageId)
    {
        // Calculate required LINK for CCIP message
        uint256 ccipFee = router.getFee(destinationChainSelector, message);

        uint256 linkBalance = linkToken.balanceOf(address(this));
        if (linkBalance < ccipFee) {
            revert UnifiedVault__InsufficientLINK(linkBalance, ccipFee);
        }

        uint256 linkAllowance = linkToken.allowance(address(this), address(router));
        if (linkAllowance < ccipFee) {
            linkToken.safeIncreaseAllowance(address(router), ccipFee - linkAllowance);
        }

        // If sending tokens, approve them
        if (message.tokenAmounts.length > 0) {
            address token = message.tokenAmounts[0].token;
            uint256 amount = message.tokenAmounts[0].amount;
            IERC20(token).safeIncreaseAllowance(address(router), amount);
        }

        // Send the CCIP message
        messageId = router.ccipSend(destinationChainSelector, message);

        emit CCIPMessageSent(messageId, destinationChainSelector);
    }

    // ==================== CCIP RECEIVER FUNCTIONS ====================

    /**
     * @notice Called by CCIPReceiver when tokens arrive via deposit
     * @dev Updates user's balance on this chain
     * @param user User address
     * @param token Token address on this chain
     * @param amount Amount to credit
     */
    function creditUser(address user, address token, uint256 amount) external onlyReceiverOrOwner {
        balances[user][token] += amount;
    }

    /**
     * @notice Called by CCIPReceiver when withdraw request arrives
     * @dev Deducts balance and emits event for CRE to send tokens back
     * @param user User address
     * @param token Token address on this chain
     * @param amount Amount to withdraw
     * @param targetChainSelector Chain to send tokens to
     */
    function executeWithdraw(address user, address token, uint256 amount, uint64 targetChainSelector)
        external
        onlyReceiverOrOwner
    {
        if (amount == 0) {
            revert UnifiedVault__InvalidAmount();
        }

        if (balances[user][token] < amount) {
            revert UnifiedVault__InsufficientBalance(token, balances[user][token], amount);
        }

        balances[user][token] -= amount;

        // Emit event for CRE orchestration
        emit WithdrawExecutionRequested(user, token, amount, targetChainSelector);
    }

    // ==================== VIEW FUNCTIONS ====================

    function getUserBalance(address user, address token) external view returns (uint256) {
        return balances[user][token];
    }
}
