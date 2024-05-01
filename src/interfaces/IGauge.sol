// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

interface IGauge is IERC20 {
    function deposit(uint256 amount) external;

    function withdraw(uint256 _value) external;

    function withdraw(uint256 _value, bool _claim_rewards) external;
}
