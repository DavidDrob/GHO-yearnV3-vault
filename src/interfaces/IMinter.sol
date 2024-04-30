// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

interface IMinter {
    function mint (
        address gauge_addr
    ) external;
}
