// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {CotejoTestBase} from "../helpers/CotejoTestBase.sol";
import {CotejoAggregatorAdapter} from "../../src/adapters/CotejoAggregatorAdapter.sol";
import {CotejoErrors} from "../../src/libraries/CotejoErrors.sol";

/// @notice The backstops. Each of these covers a path that only opens when a source
///         misbehaves in a way its own validation was supposed to prevent.
contract PriceRouterEdgesTest is CotejoTestBase {
    function setUp() public override {
        super.setUp();
        _commitRoute(WBT_USD, _defaultRoute());
    }

    /// @dev A source with a broken clock reports an observation in the future. It is dropped
    ///      rather than reverting the read: a bad clock on one feed must not brick the asset,
    ///      and INV-1 still decides whether what remains is enough.
    function test_sourceReportingTheFutureIsDroppedNotFatal() public {
        sourceA.set(100e18, 18, block.timestamp);
        sourceB.set(100e18, 18, block.timestamp);
        sourceC.set(100e18, 18, block.timestamp + 1 hours);

        (uint256 price,,) = router.latestPrice(WBT_USD);
        assertEq(price, 100e18, "a future observation is ignored, not fatal");
    }

    function test_futureReportingSourceCanBreakQuorum() public {
        sourceA.set(100e18, 18, block.timestamp);
        sourceB.set(100e18, 18, block.timestamp + 1);
        sourceC.set(100e18, 18, block.timestamp + 1);

        // Two of three dropped leaves one, below minSources.
        vm.expectRevert(
            abi.encodeWithSelector(CotejoErrors.Cotejo__InsufficientSources.selector, WBT_USD, 1, 2)
        );
        router.latestPrice(WBT_USD);
    }

    /// @dev Every source is supposed to reject a zero price itself. This is the router's
    ///      backstop for one that does not — the zero is discarded, never aggregated.
    function test_zeroPriceFromASourceIsDiscarded() public {
        sourceA.set(100e18, 18, block.timestamp);
        sourceB.set(100e18, 18, block.timestamp);
        sourceC.set(0, 18, block.timestamp);

        (uint256 price,,) = router.latestPrice(WBT_USD);
        assertEq(price, 100e18, "a zero price must never enter the set");
    }

    function test_zeroPricesCanBreakQuorum() public {
        sourceA.set(100e18, 18, block.timestamp);
        sourceB.set(0, 18, block.timestamp);
        sourceC.set(0, 18, block.timestamp);

        vm.expectRevert(
            abi.encodeWithSelector(CotejoErrors.Cotejo__InsufficientSources.selector, WBT_USD, 1, 2)
        );
        router.latestPrice(WBT_USD);
    }

    /// @dev `AggregatorV3Interface` returns a signed answer, so a price that does not fit in
    ///      an int256 cannot be represented. Reverting is the only honest option: silently
    ///      wrapping would hand a consumer a negative price.
    function test_priceExceedingInt256MaxIsRefused() public {
        CotejoAggregatorAdapter wide =
            new CotejoAggregatorAdapter(address(router), WBT_USD, 36, "WBT / USD wide");

        // Chosen so the rescaled value lands above int256.max (~5.79e76) but still inside
        // uint256 (~1.16e77), which is the only window where this check is reachable.
        uint256 colossal = 8e58;
        _setAllPrices(colossal);

        vm.expectRevert(abi.encodeWithSelector(CotejoErrors.Cotejo__PriceOverflowsInt256.selector, 8e76));
        wide.latestRoundData();
    }

    /// @dev All three sources unavailable is the ordinary total-outage case: zero fresh
    ///      sources, and the router says so rather than returning anything at all.
    function test_totalOutageRefusesCleanly() public {
        _setAllPrices(100e18);
        sourceA.setReverts(true);
        sourceB.setReverts(true);
        sourceC.setReverts(true);

        vm.expectRevert(
            abi.encodeWithSelector(CotejoErrors.Cotejo__InsufficientSources.selector, WBT_USD, 0, 2)
        );
        router.latestPrice(WBT_USD);
    }

    /// @dev Sources reporting at different scales must agree once normalised, not before.
    function test_mixedDecimalsAgreeAfterNormalisation() public {
        sourceA.set(100e18, 18, block.timestamp);
        sourceB.set(100e8, 8, block.timestamp);
        sourceC.set(100_000_000, 6, block.timestamp); // 100.000000 at 6 decimals

        (uint256 price, uint8 decimals,) = router.latestPrice(WBT_USD);
        assertEq(price, 100e18);
        assertEq(decimals, 18);
    }
}
