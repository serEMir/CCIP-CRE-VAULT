// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Client} from "@chainlink/contracts/libraries/Client.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockRouter {
    using SafeERC20 for IERC20;

    uint256 public fee;
    uint64 public lastDestinationChainSelector;
    bytes public lastReceiver;
    bytes public lastData;
    address public lastFeeToken;
    bytes public lastExtraArgs;
    address public lastToken;
    uint256 public lastTokenAmount;

    function setFee(uint256 fee_) external {
        fee = fee_;
    }

    function getFee(uint64, Client.EVM2AnyMessage memory) external view returns (uint256) {
        return fee;
    }

    function ccipSend(uint64 destinationChainSelector, Client.EVM2AnyMessage memory message)
        external
        payable
        returns (bytes32)
    {
        lastDestinationChainSelector = destinationChainSelector;
        lastReceiver = message.receiver;
        lastData = message.data;
        lastFeeToken = message.feeToken;
        lastExtraArgs = message.extraArgs;

        if (message.tokenAmounts.length > 0) {
            lastToken = message.tokenAmounts[0].token;
            lastTokenAmount = message.tokenAmounts[0].amount;
            IERC20(lastToken).safeTransferFrom(msg.sender, address(this), lastTokenAmount);
        }

        if (message.feeToken != address(0) && fee > 0) {
            IERC20(message.feeToken).safeTransferFrom(msg.sender, address(this), fee);
        }

        return keccak256(abi.encode(destinationChainSelector, message));
    }
}
