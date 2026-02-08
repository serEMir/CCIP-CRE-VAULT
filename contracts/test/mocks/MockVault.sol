// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

contract MockVault {
    address public lastCreditUser;
    address public lastCreditToken;
    uint256 public lastCreditAmount;

    address public lastWithdrawUser;
    address public lastWithdrawToken;
    uint256 public lastWithdrawAmount;
    uint64 public lastWithdrawTargetChainSelector;

    function creditUser(address user, address token, uint256 amount) external {
        lastCreditUser = user;
        lastCreditToken = token;
        lastCreditAmount = amount;
    }

    function executeWithdraw(address user, address token, uint256 amount, uint64 targetChainSelector) external {
        lastWithdrawUser = user;
        lastWithdrawToken = token;
        lastWithdrawAmount = amount;
        lastWithdrawTargetChainSelector = targetChainSelector;
    }
}
