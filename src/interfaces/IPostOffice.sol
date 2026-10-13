// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IPostOffice {
    function offices(address player) external view returns (bool);
}
