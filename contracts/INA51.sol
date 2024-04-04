// SPDX-License-Identifier: UNLICENSED

pragma solidity >=0.8.20;

interface INA51 {

    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata params) external returns (uint256 amountOut);

}