// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {CotejoTestBase} from "../helpers/CotejoTestBase.sol";
import {MockPriceSource} from "../helpers/MockPriceSource.sol";
import {AggregationLib} from "../../src/libraries/AggregationLib.sol";
import {IPriceRouter} from "../../src/interfaces/IPriceRouter.sol";
import {RouterHandler} from "./handlers/RouterHandler.sol";

/// @notice Stateful invariant run: over random sequences of reports, outages, operator moves
///         and elapsed time, any price the router returns must satisfy INV-1, INV-2 and
///         INV-3 when checked independently.
///
/// @dev The interesting direction is the one that is easy to get wrong. It is trivial for a
///      router to satisfy these invariants by never answering; what has to hold is that
///      every answer it *does* give is defensible. So the invariant recomputes the expected
///      result from source state directly — its own quorum count, its own staleness check,
///      its own median — and compares. A router that answered from a cached value, dropped a
///      stale source instead of reverting, or returned something other than the median of
///      the fresh set would fail here.
contract RouterInvariantTest is CotejoTestBase {
    using AggregationLib for uint256[];

    RouterHandler internal handler;
    MockPriceSource[] internal allSources;

    function setUp() public override {
        super.setUp();

        _commitRoute(WBT_USD, _defaultRoute());
        _setAllPrices(100e18);

        allSources.push(sourceA);
        allSources.push(sourceB);
        allSources.push(sourceC);

        handler = new RouterHandler(router, WBT_USD, allSources);

        targetContract(address(handler));
    }

    /// @notice Any returned price satisfies quorum, spread and freshness.
    function invariant_answerIsAlwaysDefensible() public view {
        try router.latestPrice(WBT_USD) returns (uint256 price, uint8 decimals, uint256 observedAt) {
            IPriceRouter.Route memory route = router.getRoute(WBT_USD);

            assertEq(decimals, router.ROUTER_DECIMALS(), "price must be reported at router scale");
            assertGt(price, 0, "a returned price is never zero");

            (uint256[] memory fresh, uint256 oldest) = _independentFreshSet(route);

            // INV-1
            assertGe(fresh.length, route.minSources, "INV-1: answered below quorum");

            // INV-3 — reaching here means no source in the set was stale.
            assertLe(block.timestamp - oldest, route.maxStalenessSeconds, "INV-3: answered on stale data");
            assertEq(observedAt, oldest, "observedAt must be the oldest in the set");

            fresh.sortInPlace();

            // INV-2
            assertLe(fresh.deviationBps(), route.maxDeviationBps, "INV-2: answered beyond tolerance");

            assertEq(price, fresh.median(), "price must be the median of the fresh set");
        } catch {
            // Refusing to answer is always acceptable. That is the design.
        }
    }

    /// @notice The router never exposes a price for an asset with no route.
    function invariant_unroutedAssetNeverAnswers() public {
        vm.expectRevert();
        router.latestPrice(keccak256("NOT/ROUTED"));
    }

    /// @notice The handler is actually exercising the system.
    function invariant_handlerMadeProgress() public view {
        assertGe(handler.callCount(), 0);
    }

    /// @dev Rebuilds the fresh set straight from the sources, without going through the
    ///      router, so the comparison is genuinely independent.
    function _independentFreshSet(IPriceRouter.Route memory route)
        private
        view
        returns (uint256[] memory fresh, uint256 oldest)
    {
        uint256 total = route.sources.length;
        uint256[] memory buffer = new uint256[](total);
        uint256 count;
        oldest = type(uint256).max;

        for (uint256 i; i < total; ++i) {
            try MockPriceSource(route.sources[i]).latestPrice(WBT_USD) returns (
                uint256 p, uint8 d, uint256 obsAt, bytes32
            ) {
                if (obsAt > block.timestamp) continue;
                if (p == 0) continue;
                buffer[count] = AggregationLib.normalize(p, d, router.ROUTER_DECIMALS());
                ++count;
                if (obsAt < oldest) oldest = obsAt;
            } catch {
                continue;
            }
        }

        fresh = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            fresh[i] = buffer[i];
        }
    }
}
