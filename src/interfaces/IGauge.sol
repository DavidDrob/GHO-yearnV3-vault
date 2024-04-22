// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IGauge {
    function deposit(uint256 amount, address receiver) external;
}
