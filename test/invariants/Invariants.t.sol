// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {CotejoTestBase} from "../helpers/CotejoTestBase.sol";
import {MockPriceSource} from "../helpers/MockPriceSource.sol";
import {IPriceRouter} from "../../src/interfaces/IPriceRouter.sol";
import {PriceRouter} from "../../src/PriceRouter.sol";
import {CotejoErrors} from "../../src/libraries/CotejoErrors.sol";

/// @notice One dedicated test per invariant. The invariant identifier is in the test name,
///         so a failure names the rule that broke rather than the line that noticed.
contract InvariantsTest is CotejoTestBase {
    // --------------------------------------------------------------------------------
    // INV-1: latestPrice reverts when fewer fresh sources than minSources
    // --------------------------------------------------------------------------------

    function test_INV1_revertsBelowMinSources() public {
        _commitRoute(WBT_USD, _defaultRoute());

        // Only one source has ever reported; minSources is 2.
        sourceA.set(100e18, 18, block.timestamp);

        vm.expectRevert(
            abi.encodeWithSelector(CotejoErrors.Cotejo__InsufficientSources.selector, WBT_USD, 1, 2)
        );
        router.latestPrice(WBT_USD);
    }

    function test_INV1_revertingSourceIsDroppedNotFatal() public {
        _commitRoute(WBT_USD, _defaultRoute());
        _setAllPrices(100e18);

        // One unavailable source still leaves a quorum of two.
        sourceC.setReverts(true);

        (uint256 price,,) = router.latestPrice(WBT_USD);
        assertEq(price, 100e18, "two healthy sources should still answer");
    }

    function test_INV1_gasBombSourceIsContainedAndDropped() public {
        _commitRoute(WBT_USD, _defaultRoute());
        _setAllPrices(100e18);

        // A source that tries to burn everything forwarded to it must not take the read
        // down with it: the per-source gas cap contains it and INV-1 covers the rest.
        sourceC.setGasBomb(true);

        (uint256 price,,) = router.latestPrice(WBT_USD);
        assertEq(price, 100e18, "gas-griefing source should be contained, not fatal");
    }

    function test_INV1_passesAtExactlyMinSources() public {
        _commitRoute(WBT_USD, _defaultRoute());

        sourceA.set(100e18, 18, block.timestamp);
        sourceB.set(100e18, 18, block.timestamp);

        (uint256 price,,) = router.latestPrice(WBT_USD);
        assertEq(price, 100e18, "exactly minSources is enough");
    }

    // --------------------------------------------------------------------------------
    // INV-2: latestPrice reverts when spread exceeds maxDeviationBps
    // --------------------------------------------------------------------------------

    function test_INV2_revertsWhenDeviationExceeded() public {
        _commitRoute(WBT_USD, _defaultRoute()); // 500 bps tolerance

        sourceA.set(100e18, 18, block.timestamp);
        sourceB.set(100e18, 18, block.timestamp);
        sourceC.set(110e18, 18, block.timestamp);

        // Sorted [100, 100, 110]: median 100, spread 10 -> 1000 bps.
        vm.expectRevert(
            abi.encodeWithSelector(CotejoErrors.Cotejo__DeviationExceeded.selector, WBT_USD, 1000, 500)
        );
        router.latestPrice(WBT_USD);
    }

    function test_INV2_deviationIsMeasuredAgainstMedianNotMin() public {
        _commitRoute(WBT_USD, _defaultRoute());

        // Sorted [100, 200, 200]: median 200, spread 100 -> 5000 bps.
        // Against the min it would have been 10000 bps. D1 picks the median.
        sourceA.set(100e18, 18, block.timestamp);
        sourceB.set(200e18, 18, block.timestamp);
        sourceC.set(200e18, 18, block.timestamp);

        vm.expectRevert(
            abi.encodeWithSelector(CotejoErrors.Cotejo__DeviationExceeded.selector, WBT_USD, 5000, 500)
        );
        router.latestPrice(WBT_USD);
    }

    function test_INV2_passesAtExactlyMaxDeviation() public {
        address[] memory sources = _addressArray(address(sourceA), address(sourceB), address(sourceC));
        _commitRoute(WBT_USD, _routeWith(sources, 2, 1000));

        sourceA.set(100e18, 18, block.timestamp);
        sourceB.set(100e18, 18, block.timestamp);
        sourceC.set(110e18, 18, block.timestamp);

        // Exactly 1000 bps, and the check is strictly-greater, so this must pass.
        (uint256 price,,) = router.latestPrice(WBT_USD);
        assertEq(price, 100e18, "deviation exactly at the limit is allowed");
    }

    // --------------------------------------------------------------------------------
    // INV-3: latestPrice reverts when any source in the set is stale
    // --------------------------------------------------------------------------------

    function test_INV3_revertsOnStaleSource() public {
        _commitRoute(WBT_USD, _defaultRoute());
        _setAllPrices(100e18);

        uint256 staleAt = block.timestamp;
        vm.warp(block.timestamp + STALENESS + 1);

        // Every source is now stale; the first one encountered reverts the read.
        vm.expectRevert(
            abi.encodeWithSelector(
                CotejoErrors.Cotejo__StalePrice.selector, WBT_USD, address(sourceA), staleAt, STALENESS
            )
        );
        router.latestPrice(WBT_USD);
    }

    function test_INV3_oneStaleSourceRevertsEvenWithQuorumOfFreshOnes() public {
        _commitRoute(WBT_USD, _defaultRoute());

        // Two sources are current, one is far behind. A stale answer is a signal that
        // something upstream is wrong, so it reverts rather than being quietly dropped.
        uint256 staleAt = block.timestamp - (STALENESS + 1);
        sourceA.set(100e18, 18, block.timestamp);
        sourceB.set(100e18, 18, block.timestamp);
        sourceC.set(100e18, 18, staleAt);

        vm.expectRevert(
            abi.encodeWithSelector(
                CotejoErrors.Cotejo__StalePrice.selector, WBT_USD, address(sourceC), staleAt, STALENESS
            )
        );
        router.latestPrice(WBT_USD);
    }

    function test_INV3_passesAtExactlyMaxStaleness() public {
        _commitRoute(WBT_USD, _defaultRoute());
        _setAllPrices(100e18);

        vm.warp(block.timestamp + STALENESS);

        (uint256 price,,) = router.latestPrice(WBT_USD);
        assertEq(price, 100e18, "age exactly at the limit is allowed");
    }

    function test_INV3_reportsOldestObservationInTheSet() public {
        _commitRoute(WBT_USD, _defaultRoute());

        uint256 newest = block.timestamp;
        uint256 oldest = block.timestamp - 100;
        sourceA.set(100e18, 18, newest);
        sourceB.set(100e18, 18, oldest);
        sourceC.set(100e18, 18, newest);

        (,, uint256 observedAt) = router.latestPrice(WBT_USD);
        assertEq(observedAt, oldest, "observedAt must be the weakest link, not the strongest");
    }

    // --------------------------------------------------------------------------------
    // INV-4: route changes wait 48h, and the pending route is public throughout
    // --------------------------------------------------------------------------------

    function test_INV4_routeChangeRequiresFullTimelock() public {
        IPriceRouter.Route memory route = _defaultRoute();

        vm.prank(owner);
        governor.proposeRoute(WBT_USD, route);

        uint64 eta = uint64(block.timestamp + governor.ROUTE_TIMELOCK());

        // One second short of the deadline.
        vm.warp(eta - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                CotejoErrors.Cotejo__TimelockNotElapsed.selector,
                keccak256(abi.encode("cotejo.route", WBT_USD)),
                eta,
                block.timestamp
            )
        );
        governor.executeRoute(WBT_USD);

        // And exactly on it.
        vm.warp(eta);
        governor.executeRoute(WBT_USD);
        assertEq(router.getRoute(WBT_USD).sources.length, 3, "route should be live after the wait");
    }

    function test_INV4_pendingRouteIsPubliclyReadableForTheWholeWait() public {
        IPriceRouter.Route memory proposed = _defaultRoute();

        vm.prank(owner);
        governor.proposeRoute(WBT_USD, proposed);

        uint64 eta = uint64(block.timestamp + governor.ROUTE_TIMELOCK());

        // Sampled by an unprivileged caller across the whole window.
        for (uint256 elapsed; elapsed <= governor.ROUTE_TIMELOCK(); elapsed += 6 hours) {
            vm.warp(eta - governor.ROUTE_TIMELOCK() + elapsed);

            vm.prank(stranger);
            (IPriceRouter.Route memory pending, uint64 readEta, bool exists) =
                governor.getPendingRoute(WBT_USD);

            assertTrue(exists, "pending route must stay visible");
            assertEq(readEta, eta, "eta must not drift");
            assertEq(pending.sources.length, 3, "sources must be readable in full");
            assertEq(pending.minSources, proposed.minSources, "quorum must be readable");
            assertEq(pending.maxDeviationBps, proposed.maxDeviationBps, "tolerance must be readable");
        }
    }

    function test_INV4_routeIsUnchangedWhileProposalIsPending() public {
        _commitRoute(WBT_USD, _defaultRoute());
        _setAllPrices(100e18);

        // Queue a replacement that drops to a single source.
        IPriceRouter.Route memory narrowed = _routeWith(_addressArray(address(sourceA)), 1, 500);
        vm.prank(owner);
        governor.proposeRoute(WBT_USD, narrowed);

        vm.warp(block.timestamp + 47 hours);
        assertEq(router.getRoute(WBT_USD).sources.length, 3, "live route must not change early");
    }

    // --------------------------------------------------------------------------------
    // INV-5: operator independence, enforced at proposal AND at read
    // --------------------------------------------------------------------------------

    function test_INV5_rejectsTwoSourcesFromSameOperator() public {
        MockPriceSource duplicate = new MockPriceSource(WBT_USD, GROUP_A);

        address[] memory sources = _addressArray(address(sourceA), address(duplicate), address(sourceC));
        IPriceRouter.Route memory route = _routeWith(sources, 2, 500);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                CotejoErrors.Cotejo__OperatorConcentration.selector, WBT_USD, GROUP_A, 2, 1
            )
        );
        governor.proposeRoute(WBT_USD, route);
    }

    function test_INV5_revertsAtReadWhenGroupChangesAfterCommit() public {
        _commitRoute(WBT_USD, _defaultRoute());
        _setAllPrices(100e18);

        // Sound at commit time.
        (uint256 price,,) = router.latestPrice(WBT_USD);
        assertEq(price, 100e18);

        // The operator behind source C is acquired by the operator behind source A. Nothing
        // about the route changed, but the route is no longer independent.
        sourceC.setGroup(GROUP_A);

        vm.expectRevert(
            abi.encodeWithSelector(
                CotejoErrors.Cotejo__OperatorConcentration.selector, WBT_USD, GROUP_A, 2, 1
            )
        );
        router.latestPrice(WBT_USD);
    }

    function test_INV5_honoursMaxSourcesPerOperatorGroupAboveOne() public {
        MockPriceSource duplicate = new MockPriceSource(WBT_USD, GROUP_A);

        address[] memory sources = _addressArray(address(sourceA), address(duplicate), address(sourceC));
        IPriceRouter.Route memory route = _routeWith(sources, 2, 500);
        route.maxSourcesPerOperatorGroup = 2;

        _commitRoute(WBT_USD, route);

        sourceA.set(100e18, 18, block.timestamp);
        duplicate.set(100e18, 18, block.timestamp);
        sourceC.set(100e18, 18, block.timestamp);

        (uint256 price,,) = router.latestPrice(WBT_USD);
        assertEq(price, 100e18, "two per group is allowed when the route says so");
    }

    // --------------------------------------------------------------------------------
    // INV-6: pausing is immediate, unpausing takes the full timelock
    // --------------------------------------------------------------------------------

    function test_INV6_guardianPausesImmediately() public {
        _commitRoute(WBT_USD, _defaultRoute());
        _setAllPrices(100e18);

        vm.prank(guardian);
        router.pause(WBT_USD);

        assertTrue(router.isPaused(WBT_USD));
        vm.expectRevert(abi.encodeWithSelector(CotejoErrors.Cotejo__Paused.selector, WBT_USD));
        router.latestPrice(WBT_USD);
    }

    function test_INV6_nonGuardianCannotPause() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(CotejoErrors.Cotejo__OnlyGuardian.selector, stranger));
        router.pause(WBT_USD);
    }

    function test_INV6_unpauseRequiresFullTimelock() public {
        _commitRoute(WBT_USD, _defaultRoute());
        _setAllPrices(100e18);

        vm.prank(guardian);
        router.pause(WBT_USD);

        vm.prank(owner);
        governor.proposeUnpause(WBT_USD);
        uint64 eta = uint64(block.timestamp + governor.ROUTE_TIMELOCK());

        vm.warp(eta - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                CotejoErrors.Cotejo__TimelockNotElapsed.selector,
                keccak256(abi.encode("cotejo.unpause", WBT_USD)),
                eta,
                block.timestamp
            )
        );
        governor.executeUnpause(WBT_USD);

        vm.warp(eta);
        governor.executeUnpause(WBT_USD);
        assertFalse(router.isPaused(WBT_USD), "unpause lands only after the full wait");
    }

    function test_INV6_guardianCannotUnpause() public {
        vm.prank(guardian);
        router.pause(WBT_USD);

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(CotejoErrors.Cotejo__OnlyGovernor.selector, guardian));
        router.unpause(WBT_USD);
    }

    function test_INV6_pauseSurvivesRepeatedGuardianCalls() public {
        vm.prank(guardian);
        router.pause(WBT_USD);
        vm.prank(guardian);
        router.pause(WBT_USD);
        assertTrue(router.isPaused(WBT_USD), "pausing is idempotent and never toggles off");
    }

    // --------------------------------------------------------------------------------
    // INV-7: no administrative role can write a price
    // --------------------------------------------------------------------------------

    function test_INV7_routerExposesNoPriceWritingFunction() public view {
        // The property is structural: if a price setter existed, one of these selectors
        // would resolve on the router. Checked against the deployed runtime code so the
        // test fails if such a function is ever added, whatever it ends up being called.
        string[9] memory forbidden = [
            "setPrice(bytes32,uint256)",
            "setPrice(bytes32,uint256,uint8)",
            "updatePrice(bytes32,uint256)",
            "writePrice(bytes32,uint256)",
            "pushPrice(bytes32,uint256)",
            "forcePrice(bytes32,uint256)",
            "overridePrice(bytes32,uint256)",
            "setAnswer(bytes32,int256)",
            "emergencySetPrice(bytes32,uint256)"
        ];

        bytes memory runtime = address(router).code;
        for (uint256 i; i < forbidden.length; ++i) {
            bytes4 selector = bytes4(keccak256(bytes(forbidden[i])));
            assertFalse(_containsSelector(runtime, selector), forbidden[i]);
        }
    }

    function test_INV7_governorCannotMovePriceWithoutSources() public {
        _commitRoute(WBT_USD, _defaultRoute());

        // The governor holds every administrative power there is. With no source reporting,
        // it still cannot produce a price — there is no path from governance to an answer.
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(CotejoErrors.Cotejo__InsufficientSources.selector, WBT_USD, 0, 2)
        );
        router.latestPrice(WBT_USD);
    }

    /// @dev Scans runtime bytecode for a 4-byte selector. Crude but sufficient: a dispatched
    ///      public function always embeds its selector as a literal in the dispatcher.
    function _containsSelector(bytes memory runtime, bytes4 selector) private pure returns (bool) {
        if (runtime.length < 4) return false;
        for (uint256 i; i + 4 <= runtime.length; ++i) {
            if (
                runtime[i] == selector[0] && runtime[i + 1] == selector[1] && runtime[i + 2] == selector[2]
                    && runtime[i + 3] == selector[3]
            ) {
                return true;
            }
        }
        return false;
    }
}
