// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {MockPriceSource} from "../../helpers/MockPriceSource.sol";
import {PriceRouter} from "../../../src/PriceRouter.sol";

/// @notice Drives a committed route through random sequences of the things that actually
///         happen to an oracle: reporters publishing, reporters going quiet, time passing,
///         sources failing, and operators consolidating.
/// @dev Deliberately allowed to produce states where the router must refuse. The invariant
///      is not that the router always answers — it is that any answer it does give is sound.
contract RouterHandler is CommonBase, StdUtils {
    PriceRouter public immutable router;
    bytes32 public immutable asset;

    MockPriceSource[] public sources;
    bytes32[] public groups;

    uint256 public callCount;

    constructor(PriceRouter router_, bytes32 asset_, MockPriceSource[] memory sources_) {
        router = router_;
        asset = asset_;
        for (uint256 i; i < sources_.length; ++i) {
            sources.push(sources_[i]);
        }
        groups.push(keccak256("operator.a"));
        groups.push(keccak256("operator.b"));
        groups.push(keccak256("operator.c"));
    }

    /// @notice A reporter publishes a fresh price.
    function report(uint256 sourceSeed, uint256 priceSeed) external {
        MockPriceSource source = _pick(sourceSeed);
        uint256 price = bound(priceSeed, 1e15, 1e24);
        source.set(price, 18, block.timestamp);
        ++callCount;
    }

    /// @notice A reporter publishes at an older timestamp, modelling a lagging feed.
    function reportStale(uint256 sourceSeed, uint256 priceSeed, uint256 ageSeed) external {
        MockPriceSource source = _pick(sourceSeed);
        uint256 price = bound(priceSeed, 1e15, 1e24);
        uint256 age = bound(ageSeed, 0, 3_000);
        uint256 observedAt = block.timestamp > age ? block.timestamp - age : 0;
        if (observedAt == 0) observedAt = 1;
        source.set(price, 18, observedAt);
        ++callCount;
    }

    /// @notice A reporter publishes at a different scale, exercising normalisation.
    function reportWithDecimals(uint256 sourceSeed, uint256 priceSeed, uint256 decimalsSeed) external {
        MockPriceSource source = _pick(sourceSeed);
        uint8 decimals = uint8(bound(decimalsSeed, 6, 18));
        uint256 price = bound(priceSeed, 1, 1e12) * (10 ** uint256(decimals)) / 1e6;
        if (price == 0) price = 1;
        source.set(price, decimals, block.timestamp);
        ++callCount;
    }

    /// @notice A source goes down, or comes back.
    function setAvailability(uint256 sourceSeed, bool available) external {
        _pick(sourceSeed).setReverts(!available);
        ++callCount;
    }

    /// @notice An operator consolidation moves a source into another group.
    function reassignOperator(uint256 sourceSeed, uint256 groupSeed) external {
        _pick(sourceSeed).setGroup(groups[bound(groupSeed, 0, groups.length - 1)]);
        ++callCount;
    }

    /// @notice Time passes.
    function advanceTime(uint256 secondsSeed) external {
        vm.warp(block.timestamp + bound(secondsSeed, 1, 1_200));
        ++callCount;
    }

    function sourceCount() external view returns (uint256) {
        return sources.length;
    }

    function _pick(uint256 seed) private view returns (MockPriceSource) {
        return sources[bound(seed, 0, sources.length - 1)];
    }
}
