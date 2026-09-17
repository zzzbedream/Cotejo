// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {MarketTestBase} from "./helpers/MarketTestBase.sol";
import {MarketErrors} from "../../src/market/libraries/MarketErrors.sol";

/// @notice The depth-aware debt ceiling, and the line it must not cross.
///
/// @dev A market cannot owe more than its liquidators could plausibly unwind. But a fall in
///      observed liquidity must never, by itself, make anyone liquidatable: that would turn
///      "the book got thinner" into a liquidation trigger, and hand anyone who can move depth
///      a way to force liquidations without touching a price.
contract DepthCapTest is MarketTestBase {
    uint256 internal constant SUPPLY = 5_000_000e6;
    uint256 internal constant COLLATERAL = 20_000e18; // $2M at $100
    uint256 internal constant BORROW = 1_500_000e6; // inside both LLTV and the cap

    function setUp() public override {
        super.setUp();
        _supply(SUPPLY);
        _postCollateral(borrower, COLLATERAL);
        _borrow(borrower, BORROW);
    }

    function test_DepthCapBlocksBorrowNotLiquidation() public {
        // Baseline: $4M observed depth, half of it borrowable, and 1.5M drawn.
        assertEq(market.maxTotalBorrow(params), 2_000_000e6, "cap is half the observed depth");
        assertTrue(market.isHealthy(params, borrower), "position starts healthy");

        // Liquidity dries up. Every reporter now sees a quarter of the book it saw before.
        // The price does not move at all.
        _refreshWithDepth(1_000_000);

        // --- The cap follows the depth down. ---
        assertEq(market.maxTotalBorrow(params), 500_000e6, "cap tracks the fall immediately");

        // --- (a) New borrowing is blocked. ---
        // Matched on the selector: the reported figure carries the interest that accrued
        // during the heartbeat, which is correct and not worth pinning to the wei.
        vm.prank(borrower);
        vm.expectPartialRevert(MarketErrors.Market__DepthCapExceeded.selector);
        market.borrow(params, 1e6, 0, borrower, borrower);

        // --- (b) The existing position is untouched and still solvent. ---
        assertTrue(market.isHealthy(params, borrower), "a thinner book does not make a borrower unhealthy");

        // --- (c) And therefore not liquidatable. ---
        vm.prank(liquidator);
        vm.expectRevert(abi.encodeWithSelector(MarketErrors.Market__HealthyPosition.selector, id, borrower));
        market.liquidate(params, borrower, 100e18, 0);

        // --- (d) Repaying still works, which is how the market gets back under the cap. ---
        vm.prank(supplier);
        loan.transfer(borrower, 1_100_000e6);
        vm.prank(borrower);
        market.repay(params, 1_100_000e6, 0, borrower);

        assertLe(
            market.marketOf(id).totalBorrowAssets,
            market.maxTotalBorrow(params),
            "the market can return under its own ceiling"
        );
    }

    /// @dev Once back under the ceiling, borrowing resumes without any intervention.
    function test_DepthCap_borrowResumesOnceUnderTheCeiling() public {
        _refreshWithDepth(1_000_000);

        vm.prank(supplier);
        loan.transfer(borrower, 1_200_000e6);
        vm.prank(borrower);
        market.repay(params, 1_200_000e6, 0, borrower);

        vm.prank(borrower);
        market.borrow(params, 1_000e6, 0, borrower, borrower);
    }

    /// @notice M1. Depth cannot be inflated instantly to lift the ceiling before a big borrow.
    /// @dev Growth is clamped to 2500 bps per hour against the last accepted observation.
    ///      Rejecting outright would block borrowing on any upward spike, including an honest
    ///      recovery; clamping removes the benefit of the spike while letting the figure climb
    ///      at a bounded rate.
    function test_DepthCap_growthIsClampedAgainstInstantInflation() public {
        uint256 anchoredCap = market.maxTotalBorrow(params);

        // One hour later, every reporter claims ten times the depth.
        _refreshWithDepthAfter(3600, BASE_DEPTH_USD * 10);

        uint256 clampedCap = market.maxTotalBorrow(params);

        // 2500 bps of 4M over one hour is 1M of growth, so 5M total, so a 2.5M cap.
        assertEq(clampedCap, 2_500_000e6, "growth is capped at 25% per hour");
        assertLt(clampedCap, anchoredCap * 10, "a tenfold claim cannot produce a tenfold ceiling in one step");
    }

    /// @dev Falls are deliberately not clamped. Less liquidity takes effect at once, which is
    ///      the conservative direction; delaying it would let a market keep borrowing against
    ///      depth that has already gone.
    function test_DepthCap_fallsApplyImmediately() public {
        _refreshWithDepth(BASE_DEPTH_USD / 8);
        assertEq(market.maxTotalBorrow(params), 250_000e6, "the drop is not smoothed");
    }

    /// @notice M1, as amended. The binding depth is the **second**-lowest a fresh source
    ///         reports, not the lowest.
    ///
    /// @dev The trade is exact and it costs something real:
    ///
    ///        lowest        — one honest reporter holds the ceiling down, but one malicious
    ///                        reporter drives it to zero and blocks every borrow on the route.
    ///        second-lowest — two liars are needed to inflate it, and two to deny it.
    ///
    ///      Giving up "one honest reporter is enough" is only defensible because
    ///      `MAX_ADAPTER_DEBT_USD` bounds the loss without consulting any reporter at all.
    ///      The three tests below pin the gain, the loss, and the compensating control.
    function test_DepthCap_secondLowestSurvivesASingleDenialAttempt() public {
        vm.warp(block.timestamp + HEARTBEAT);
        // One reporter claims the book is effectively empty. Under the old minimum statistic
        // this alone drove the ceiling to zero and froze borrowing for everyone.
        _attest(0, COL_ASSET, COL_PRICE_USD, 1, block.timestamp);
        _attest(0, LOAN_ASSET, LOAN_PRICE_USD, 1, block.timestamp);
        for (uint256 i = 1; i < SOURCE_COUNT; ++i) {
            _attest(i, COL_ASSET, COL_PRICE_USD, BASE_DEPTH_USD, block.timestamp);
            _attest(i, LOAN_ASSET, LOAN_PRICE_USD, BASE_DEPTH_USD, block.timestamp);
        }

        assertEq(adapter.bindingDepthUsd(), BASE_DEPTH_USD, "one liar cannot deny the route");

        vm.prank(borrower);
        market.borrow(params, 1_000e6, 0, borrower, borrower);
    }

    function test_DepthCap_twoHonestReportersStillBindIt() public {
        vm.warp(block.timestamp + HEARTBEAT);
        for (uint256 i; i < SOURCE_COUNT; ++i) {
            uint256 depth = i < 2 ? 900_000 : 100_000_000;
            _attest(i, COL_ASSET, COL_PRICE_USD, depth, block.timestamp);
            _attest(i, LOAN_ASSET, LOAN_PRICE_USD, depth, block.timestamp);
        }

        assertEq(adapter.bindingDepthUsd(), 900_000, "two agreeing honest reporters bind it");
    }

    /// @dev The honest statement of what was given up. A single truthful reporter no longer
    ///      holds the ceiling down — four liars outvote them. What stops the damage is not the
    ///      depth statistic at all: it is the growth clamp, and behind it the hard ceiling that
    ///      no reporter can influence.
    function test_DepthCap_oneHonestReporterNoLongerBindsButTheOtherLimitsDo() public {
        vm.warp(block.timestamp + HEARTBEAT);
        for (uint256 i; i < SOURCE_COUNT - 1; ++i) {
            _attest(i, COL_ASSET, COL_PRICE_USD, 100_000_000, block.timestamp);
            _attest(i, LOAN_ASSET, LOAN_PRICE_USD, 100_000_000, block.timestamp);
        }
        _attest(SOURCE_COUNT - 1, COL_ASSET, COL_PRICE_USD, 800_000, block.timestamp);
        _attest(SOURCE_COUNT - 1, LOAN_ASSET, LOAN_PRICE_USD, 800_000, block.timestamp);

        // The raw statistic follows the liars.
        assertEq(adapter.bindingDepthUsd(), 100_000_000, "the lone honest reporter is outvoted");

        // But the ceiling does not: the growth clamp holds it near the anchor, and
        // MAX_ADAPTER_DEBT_USD sits behind that regardless of what anyone reports.
        // 2500 bps/hour over the 300s heartbeat is ~2% of growth: the anchor moves from 4M to
        // ~4.083M, and the ceiling is half of that. A 25x claim buys 2%.
        uint256 cap = market.maxTotalBorrow(params);
        assertEq(cap, 2_041_666e6, "the clamp lets a 25x claim move the ceiling by ~2%");
        assertLt(cap, 50_000_000e6, "the unclamped claim would have supported 50M");
        assertLe(
            cap,
            MAX_ADAPTER_DEBT_USD * 10 ** LOAN_DECIMALS,
            "and the report-independent ceiling bounds it regardless"
        );
    }

    // --------------------------------------------------------------------------------

    function _refreshWithDepth(uint256 depthUsd) internal {
        _refreshWithDepthAfter(HEARTBEAT, depthUsd);
    }

    function _refreshWithDepthAfter(uint256 secondsForward, uint256 depthUsd) internal {
        vm.warp(block.timestamp + secondsForward);
        for (uint256 i; i < SOURCE_COUNT; ++i) {
            _attest(i, COL_ASSET, COL_PRICE_USD, depthUsd, block.timestamp);
            _attest(i, LOAN_ASSET, LOAN_PRICE_USD, depthUsd, block.timestamp);
        }
    }
}
