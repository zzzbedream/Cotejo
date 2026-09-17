// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {PriceRouter} from "../../src/PriceRouter.sol";
import {RouteGovernor} from "../../src/RouteGovernor.sol";
import {IPriceRouter} from "../../src/interfaces/IPriceRouter.sol";
import {MockPriceSource} from "./MockPriceSource.sol";

/// @notice Shared wiring for Cotejo tests: a router bound to its governor, a guardian, and
///         three independent mock sources for WBT/USD.
abstract contract CotejoTestBase is Test {
    bytes32 internal constant WBT_USD = keccak256("WBT/USD");

    bytes32 internal constant GROUP_A = keccak256("operator.a");
    bytes32 internal constant GROUP_B = keccak256("operator.b");
    bytes32 internal constant GROUP_C = keccak256("operator.c");

    uint32 internal constant HEARTBEAT = 300;
    uint32 internal constant STALENESS = 900;

    address internal owner = makeAddr("owner");
    address internal guardian = makeAddr("guardian");
    address internal stranger = makeAddr("stranger");

    PriceRouter internal router;
    RouteGovernor internal governor;

    MockPriceSource internal sourceA;
    MockPriceSource internal sourceB;
    MockPriceSource internal sourceC;

    function setUp() public virtual {
        // Start well past the epoch so staleness arithmetic is realistic.
        vm.warp(1_750_000_000);

        router = new PriceRouter(owner);
        governor = new RouteGovernor(address(router), owner);

        vm.prank(owner);
        router.setGovernor(address(governor));

        _grantGuardian(guardian);

        sourceA = new MockPriceSource(WBT_USD, GROUP_A);
        sourceB = new MockPriceSource(WBT_USD, GROUP_B);
        sourceC = new MockPriceSource(WBT_USD, GROUP_C);
    }

    /// @dev A6.3. Granting the pause power now waits out the full timelock, because pausing an
    ///      asset freezes liquidation in every market that uses it. Revoking stays immediate.
    function _grantGuardian(address who) internal {
        vm.prank(owner);
        governor.proposeGuardian(who);
        vm.warp(block.timestamp + governor.ROUTE_TIMELOCK());
        governor.executeGuardian(who);
    }

    // --------------------------------------------------------------------------------
    // Route helpers
    // --------------------------------------------------------------------------------

    /// @dev A three-source route with one source per operator group.
    function _defaultRoute() internal view returns (IPriceRouter.Route memory route) {
        address[] memory sources = new address[](3);
        sources[0] = address(sourceA);
        sources[1] = address(sourceB);
        sources[2] = address(sourceC);
        return IPriceRouter.Route({
            sources: sources,
            minSources: 2,
            maxDeviationBps: 500,
            maxStalenessSeconds: STALENESS,
            reporterHeartbeatSeconds: HEARTBEAT,
            maxSourcesPerOperatorGroup: 1
        });
    }

    function _routeWith(address[] memory sources, uint8 minSources, uint16 maxDeviationBps)
        internal
        pure
        returns (IPriceRouter.Route memory route)
    {
        return IPriceRouter.Route({
            sources: sources,
            minSources: minSources,
            maxDeviationBps: maxDeviationBps,
            maxStalenessSeconds: STALENESS,
            reporterHeartbeatSeconds: HEARTBEAT,
            maxSourcesPerOperatorGroup: 1
        });
    }

    /// @dev Propose, wait out the full timelock, execute. The normal path for a route.
    function _commitRoute(bytes32 asset, IPriceRouter.Route memory route) internal {
        vm.prank(owner);
        governor.proposeRoute(asset, route);
        vm.warp(block.timestamp + governor.ROUTE_TIMELOCK());
        governor.executeRoute(asset);
    }

    /// @dev Points all three sources at the same price, observed now.
    function _setAllPrices(uint256 price) internal {
        sourceA.set(price, 18, block.timestamp);
        sourceB.set(price, 18, block.timestamp);
        sourceC.set(price, 18, block.timestamp);
    }

    function _addressArray(address a) internal pure returns (address[] memory out) {
        out = new address[](1);
        out[0] = a;
    }

    function _addressArray(address a, address b) internal pure returns (address[] memory out) {
        out = new address[](2);
        out[0] = a;
        out[1] = b;
    }

    function _addressArray(address a, address b, address c) internal pure returns (address[] memory out) {
        out = new address[](3);
        out[0] = a;
        out[1] = b;
        out[2] = c;
    }
}
