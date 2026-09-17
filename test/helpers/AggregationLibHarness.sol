// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AggregationLib} from "../../src/libraries/AggregationLib.sol";

/// @notice External wrappers around `AggregationLib`.
/// @dev The library's functions are `internal` and inline into their caller, so a revert
///      raised inside one is not a call boundary and `vm.expectRevert` cannot see it. Going
///      through this harness gives each one a real call frame.
contract AggregationLibHarness {
    function median(uint256[] memory xs) external pure returns (uint256) {
        return AggregationLib.median(xs);
    }

    function deviationBps(uint256[] memory xs) external pure returns (uint256) {
        return AggregationLib.deviationBps(xs);
    }

    function normalize(uint256 price, uint8 from, uint8 to) external pure returns (uint256) {
        return AggregationLib.normalize(price, from, to);
    }

    function sorted(uint256[] memory xs) external pure returns (uint256[] memory) {
        AggregationLib.sortInPlace(xs);
        return xs;
    }
}
