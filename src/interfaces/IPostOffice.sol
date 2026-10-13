// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Read interface of the Courier World PostOffice at 0x26D80804D0FA2F4598369E0062bFC9536d115D82 on
/// Robinhood Chain (chain id 4663). `offices` is the public getter of `mapping(address => Office)`, so it returns
/// every fixed-size field of the Office struct; the first returned word, `open`, is the only one MoonRewards reads.
interface IPostOffice {
    function offices(address player)
        external
        view
        returns (
            bool open,
            uint8 tier,
            uint8 onDuty,
            uint16 routesUsed,
            uint64 lastUpgrade,
            address referrer,
            uint256 power,
            uint256 rewardDebt,
            uint256 pending
        );
}
