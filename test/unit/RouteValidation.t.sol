// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {CotejoTestBase} from "../helpers/CotejoTestBase.sol";
import {MockPriceSource} from "../helpers/MockPriceSource.sol";
import {PriceRouter} from "../../src/PriceRouter.sol";
import {RouteGovernor} from "../../src/RouteGovernor.sol";
import {IPriceRouter} from "../../src/interfaces/IPriceRouter.sol";
import {AggregationLib} from "../../src/libraries/AggregationLib.sol";
import {CotejoErrors} from "../../src/libraries/CotejoErrors.sol";

/// @notice Route configuration rules, including D2 and D4.
contract RouteValidationTest is CotejoTestBase {
    function test_rejectsEmptySourceList() public {
        IPriceRouter.Route memory route = _routeWith(new address[](0), 1, 500);

        vm.prank(owner);
        vm.expectRevert(CotejoErrors.Cotejo__EmptyRoute.selector);
        governor.proposeRoute(WBT_USD, route);
    }

    function test_rejectsZeroMinSources() public {
        IPriceRouter.Route memory route = _routeWith(_addressArray(address(sourceA)), 0, 500);

        vm.prank(owner);
        vm.expectRevert(CotejoErrors.Cotejo__EmptyRoute.selector);
        governor.proposeRoute(WBT_USD, route);
    }

    /// @dev D4: MAX_SOURCES_PER_ROUTE is 15, and the cap is enforced at configuration so the
    ///      cost of a read stays bounded for whoever calls it under pressure.
    function test_rejectsMoreThanFifteenSources() public {
        address[] memory sources = new address[](16);
        for (uint256 i; i < 16; ++i) {
            sources[i] = address(new MockPriceSource(WBT_USD, keccak256(abi.encode("op", i))));
        }
        IPriceRouter.Route memory route = _routeWith(sources, 2, 500);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CotejoErrors.Cotejo__TooManySources.selector, 16, 15));
        governor.proposeRoute(WBT_USD, route);
    }

    function test_acceptsExactlyFifteenSources() public {
        address[] memory sources = new address[](15);
        for (uint256 i; i < 15; ++i) {
            sources[i] = address(new MockPriceSource(WBT_USD, keccak256(abi.encode("op", i))));
        }
        _commitRoute(WBT_USD, _routeWith(sources, 2, 500));

        assertEq(router.getRoute(WBT_USD).sources.length, 15);
        assertEq(router.MAX_SOURCES_PER_ROUTE(), AggregationLib.MAX_SOURCES_PER_ROUTE);
    }

    function test_rejectsUnreachableQuorum() public {
        IPriceRouter.Route memory route =
            _routeWith(_addressArray(address(sourceA), address(sourceB)), 3, 500);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CotejoErrors.Cotejo__MinSourcesUnreachable.selector, 3, 2));
        governor.proposeRoute(WBT_USD, route);
    }

    /// @dev D2: a staleness window under two heartbeats makes normal operation revert at
    ///      random, and nobody is able to explain why. Rejected up front.
    function test_rejectsStalenessBelowTwoHeartbeats() public {
        IPriceRouter.Route memory route = _defaultRoute();
        route.reporterHeartbeatSeconds = 300;
        route.maxStalenessSeconds = 599; // one second short of two heartbeats

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(CotejoErrors.Cotejo__StalenessBelowHeartbeat.selector, 599, 300)
        );
        governor.proposeRoute(WBT_USD, route);
    }

    function test_acceptsStalenessAtExactlyTwoHeartbeats() public {
        IPriceRouter.Route memory route = _defaultRoute();
        route.reporterHeartbeatSeconds = 300;
        route.maxStalenessSeconds = 600;

        _commitRoute(WBT_USD, route);
        assertEq(router.getRoute(WBT_USD).maxStalenessSeconds, 600);
    }

    function test_rejectsZeroValuedParameters() public {
        vm.startPrank(owner);

        IPriceRouter.Route memory noDeviation = _defaultRoute();
        noDeviation.maxDeviationBps = 0;
        vm.expectRevert(CotejoErrors.Cotejo__InvalidRouteParameter.selector);
        governor.proposeRoute(WBT_USD, noDeviation);

        IPriceRouter.Route memory noStaleness = _defaultRoute();
        noStaleness.maxStalenessSeconds = 0;
        vm.expectRevert(CotejoErrors.Cotejo__InvalidRouteParameter.selector);
        governor.proposeRoute(WBT_USD, noStaleness);

        IPriceRouter.Route memory noHeartbeat = _defaultRoute();
        noHeartbeat.reporterHeartbeatSeconds = 0;
        vm.expectRevert(CotejoErrors.Cotejo__InvalidRouteParameter.selector);
        governor.proposeRoute(WBT_USD, noHeartbeat);

        IPriceRouter.Route memory noGroupCap = _defaultRoute();
        noGroupCap.maxSourcesPerOperatorGroup = 0;
        vm.expectRevert(CotejoErrors.Cotejo__InvalidRouteParameter.selector);
        governor.proposeRoute(WBT_USD, noGroupCap);

        vm.stopPrank();
    }

    function test_rejectsZeroAddressSource() public {
        IPriceRouter.Route memory route = _routeWith(_addressArray(address(0)), 1, 500);

        vm.prank(owner);
        vm.expectRevert(CotejoErrors.Cotejo__InvalidRouteParameter.selector);
        governor.proposeRoute(WBT_USD, route);
    }

    function test_rejectsSourceThatDoesNotServeTheAsset() public {
        MockPriceSource other = new MockPriceSource(keccak256("ETH/USD"), GROUP_A);
        IPriceRouter.Route memory route = _routeWith(_addressArray(address(sourceA), address(other)), 1, 500);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                CotejoErrors.Cotejo__SourceDoesNotServeAsset.selector, address(other), WBT_USD
            )
        );
        governor.proposeRoute(WBT_USD, route);
    }

    function test_readingAnUnconfiguredAssetReverts() public {
        vm.expectRevert(abi.encodeWithSelector(CotejoErrors.Cotejo__RouteNotConfigured.selector, WBT_USD));
        router.latestPrice(WBT_USD);
    }

    // --------------------------------------------------------------------------------
    // Access control on the router itself
    // --------------------------------------------------------------------------------

    function test_onlyGovernorMayCommitRoutes() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(CotejoErrors.Cotejo__OnlyGovernor.selector, stranger));
        router.commitRoute(WBT_USD, _defaultRoute());
    }

    function test_onlyGovernorMaySetGuardians() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(CotejoErrors.Cotejo__OnlyGovernor.selector, stranger));
        router.setGuardian(stranger, true);
    }

    function test_unpauseRevertsWhenNotPaused() public {
        vm.prank(address(governor));
        vm.expectRevert(abi.encodeWithSelector(CotejoErrors.Cotejo__NotPaused.selector, WBT_USD));
        router.unpause(WBT_USD);
    }

    function test_governorCanOnlyBeSetOnce() public {
        PriceRouter fresh = new PriceRouter(owner);
        RouteGovernor firstGovernor = new RouteGovernor(address(fresh), owner);

        vm.startPrank(owner);
        fresh.setGovernor(address(firstGovernor));
        assertEq(fresh.governor(), address(firstGovernor));

        vm.expectRevert(CotejoErrors.Cotejo__InvalidRouteParameter.selector);
        fresh.setGovernor(makeAddr("secondGovernor"));

        vm.stopPrank();
    }

    function test_governorCannotBeZero() public {
        PriceRouter fresh = new PriceRouter(owner);

        vm.prank(owner);
        vm.expectRevert(CotejoErrors.Cotejo__InvalidRouteParameter.selector);
        fresh.setGovernor(address(0));
    }

    function test_onlyOwnerMaySetGovernor() public {
        PriceRouter fresh = new PriceRouter(owner);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        fresh.setGovernor(makeAddr("governor"));
    }

    function test_guardianCannotBeZero() public {
        vm.prank(address(governor));
        vm.expectRevert(CotejoErrors.Cotejo__InvalidRouteParameter.selector);
        router.setGuardian(address(0), true);
    }

    function test_routerConstantsAreAsSpecified() public view {
        assertEq(router.ROUTER_DECIMALS(), 18);
        assertEq(router.SOURCE_GAS_LIMIT(), 200_000);
        assertEq(router.MAX_SOURCES_PER_ROUTE(), 15);
    }
}
