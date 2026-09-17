// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {CotejoTestBase} from "../helpers/CotejoTestBase.sol";
import {CotejoErrors} from "../../src/libraries/CotejoErrors.sol";

/// @notice Reproduces the single-source price-runaway scenario dated 30 August 2026.
///
/// @dev Scenario as specified for this build: one source reports an asset whose price
///      multiplies by 100 over 20 minutes, while the other two sources stay flat. The
///      compromised feed keeps publishing on schedule throughout, so it never looks stale —
///      it looks healthy and wrong, which is the harder case. A single-source oracle, or an
///      aggregator that averages without a spread bound, would have carried that number
///      straight into every protocol reading it, marking collateral at 100x and letting an
///      attacker borrow against it.
///
///      Note on provenance: the incident details above are reproduced from the specification
///      this contract was built against. They are not drawn from independent knowledge of
///      the event, so the comment deliberately describes the mechanism rather than asserting
///      specifics — attribution, venue, loss size — that this repository cannot verify.
///
///      What the test pins down is Cotejo's behaviour under that mechanism: the router
///      refuses to answer. The spread against the median blows past any sane tolerance long
///      before the ramp completes, and `Cotejo__DeviationExceeded` is what a consumer sees.
///      Refusing is the whole point. A lending market that cannot read a price does not
///      liquidate anyone; a lending market that reads a 100x price liquidates everyone.
contract TectonicScenarioTest is CotejoTestBase {
    /// @dev The ramp runs for 20 minutes in heartbeat-sized steps, so honest reporters stay
    ///      fresh and INV-3 never fires. This isolates INV-2 as the control that catches it.
    uint256 private constant RAMP_DURATION = 20 minutes;
    uint256 private constant STEPS = RAMP_DURATION / HEARTBEAT; // 4 steps of 300s

    uint256 private constant START_PRICE = 100e18;
    uint256 private constant END_PRICE = 100 * START_PRICE;

    function test_TectonicScenario() public {
        _commitRoute(WBT_USD, _defaultRoute()); // minSources 2, 500 bps, 900s staleness

        // Baseline: three independent operators agree, the router answers normally.
        _setAllPrices(START_PRICE);
        (uint256 healthy,,) = router.latestPrice(WBT_USD);
        assertEq(healthy, START_PRICE, "baseline price should be readable");

        // The ramp. Source C is compromised and climbs towards 100x. A and B keep reporting
        // the true price on every heartbeat, so the set never goes stale.
        bool reverted;
        for (uint256 step = 1; step <= STEPS; ++step) {
            vm.warp(block.timestamp + HEARTBEAT);

            uint256 corrupted = START_PRICE + ((END_PRICE - START_PRICE) * step) / STEPS;

            sourceA.set(START_PRICE, 18, block.timestamp);
            sourceB.set(START_PRICE, 18, block.timestamp);
            sourceC.set(corrupted, 18, block.timestamp);

            try router.latestPrice(WBT_USD) {
            // Still within tolerance: only acceptable on the earliest steps.
            }
            catch {
                reverted = true;
                break;
            }
        }

        assertTrue(reverted, "the router must stop answering during the ramp");

        // At the end of the ramp the numbers are exact and worth asserting on:
        // sorted [100, 100, 10000] -> median 100, spread 9900 -> 990_000 bps against 500.
        vm.warp(block.timestamp + HEARTBEAT);
        sourceA.set(START_PRICE, 18, block.timestamp);
        sourceB.set(START_PRICE, 18, block.timestamp);
        sourceC.set(END_PRICE, 18, block.timestamp);

        vm.expectRevert(
            abi.encodeWithSelector(CotejoErrors.Cotejo__DeviationExceeded.selector, WBT_USD, 990_000, 500)
        );
        router.latestPrice(WBT_USD);
    }

    /// @dev The mirror case. A compromised source crashing towards zero is the direction that
    ///      triggers liquidations, and D1's median base measures it less harshly than the
    ///      upward case (see `AggregationLib.deviationBps`). It must still be caught.
    function test_TectonicScenario_downwardRunawayIsAlsoRefused() public {
        _commitRoute(WBT_USD, _defaultRoute());

        sourceA.set(START_PRICE, 18, block.timestamp);
        sourceB.set(START_PRICE, 18, block.timestamp);
        sourceC.set(START_PRICE / 100, 18, block.timestamp);

        // sorted [1, 100, 100] -> median 100, spread 99 -> 9900 bps.
        vm.expectRevert(
            abi.encodeWithSelector(CotejoErrors.Cotejo__DeviationExceeded.selector, WBT_USD, 9900, 500)
        );
        router.latestPrice(WBT_USD);
    }

    /// @dev A guardian watching the ramp can stop the asset outright, and lifting that pause
    ///      then takes the full 48 hours — long enough for humans to look at it.
    function test_TectonicScenario_guardianCanHaltAndUnpauseIsSlow() public {
        _commitRoute(WBT_USD, _defaultRoute());
        _setAllPrices(START_PRICE);

        vm.prank(guardian);
        router.pause(WBT_USD);

        vm.expectRevert(abi.encodeWithSelector(CotejoErrors.Cotejo__Paused.selector, WBT_USD));
        router.latestPrice(WBT_USD);

        vm.prank(owner);
        governor.proposeUnpause(WBT_USD);

        vm.warp(block.timestamp + 47 hours);
        vm.expectRevert();
        governor.executeUnpause(WBT_USD);
    }
}
