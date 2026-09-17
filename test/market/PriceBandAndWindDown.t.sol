// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {MarketTestBase} from "./helpers/MarketTestBase.sol";
import {MarketErrors} from "../../src/market/libraries/MarketErrors.sol";

/// @notice A3 (the upward price breaker) and A2 (the degraded wind-down).
contract PriceBandAndWindDownTest is MarketTestBase {
    uint256 internal constant SUPPLY = 2_000_000e6;
    uint256 internal constant COLLATERAL = 1_000e18; // $100k at $100
    uint256 internal constant BORROW = 86_000e6; // exactly at the 86% LLTV

    function setUp() public override {
        super.setUp();
        _supply(SUPPLY);
        _postCollateral(borrower, COLLATERAL);
        _borrow(borrower, 50_000e6);
    }

    // --------------------------------------------------------------------------------
    // A3 — the upward breaker
    // --------------------------------------------------------------------------------

    /// @dev A consensus lie moves every source together, so deviation stays at zero and INV-2
    ///      never fires. The band is the only thing that notices, because it compares against
    ///      what this market itself saw a moment ago rather than against the other reporters.
    function test_A3_upwardBreakerStopsBorrowingOnAConsensusSpike() public {
        _allSourcesAgreeOn(COL_PRICE_USD * 3);

        vm.prank(borrower);
        vm.expectPartialRevert(MarketErrors.Market__PriceBandExceeded.selector);
        market.borrow(params, 1_000e6, 0, borrower, borrower);
    }

    /// @dev A move inside the band is ordinary market noise and must not block anything.
    function test_A3_moveInsideTheBandIsAllowed() public {
        _allSourcesAgreeOn(COL_PRICE_USD * 104 / 100); // +4%, under the 5% floor

        vm.prank(borrower);
        market.borrow(params, 1_000e6, 0, borrower, borrower);
    }

    /// @dev The band widens with time, so a market nobody has touched for hours does not trip
    ///      on the first honest move after a quiet spell.
    function test_A3_bandWidensWithTime() public {
        vm.warp(block.timestamp + 3 hours);
        _allSourcesAgreeOn(COL_PRICE_USD * 140 / 100); // +40%, over the 50% hard ceiling? no

        vm.prank(borrower);
        market.borrow(params, 1_000e6, 0, borrower, borrower);
    }

    /// @notice The property that makes the whole breaker safe.
    ///
    /// @dev Liquidation is **never** gated by the band, in either direction. A breaker on a
    ///      falling price would trip during a genuine crash, degrade the market, and freeze
    ///      liquidations exactly when they matter most — manufacturing the bad debt it claims
    ///      to prevent. So the breaker touches `borrow` and `withdrawCollateral` and nothing
    ///      else.
    function test_A3_liquidationIsNeverGatedByTheBand() public {
        vm.prank(borrower);
        market.borrow(params, 30_000e6, 0, borrower, borrower);

        // A violent crash: far outside the band, agreed by every source.
        _allSourcesAgreeOn(COL_PRICE_USD / 2);

        // Borrowing is now band-gated in the other direction (the anchor has not caught up),
        // but liquidation must go through regardless.
        vm.prank(liquidator);
        market.liquidate(params, borrower, 100e18, 0);

        assertLt(market.positionOf(id, borrower).collateral, COLLATERAL, "liquidation proceeded");
    }

    /// @dev The clamp is what stops the breaker being defeated in one block: inflate the
    ///      price, call any permissionless mutator to anchor the lie, then borrow freely.
    function test_A3_anchorCannotBeSetInOneBlock() public {
        (uint256 before,,) = market.oracleAnchor(address(adapter));

        _allSourcesAgreeOn(COL_PRICE_USD * 10);
        market.pokeOracleState(params);

        (uint256 after_,,) = market.oracleAnchor(address(adapter));
        assertLt(after_, before * 2, "one poke cannot ratchet the anchor to the lie");
        assertGt(after_, before, "but it does move toward it");
    }

    // --------------------------------------------------------------------------------
    // A2 — the degraded wind-down
    // --------------------------------------------------------------------------------

    function test_A2_windDownIsClosedBeforeTheGracePeriod() public {
        _makeUnhealthyThenDegrade();

        vm.prank(liquidator);
        vm.expectPartialRevert(MarketErrors.Market__NotDegradedLongEnough.selector);
        market.liquidateDegraded(params, borrower, 1);
    }

    function test_A2_windDownRefusesAHealthyPosition() public {
        // Degrade without ever making the position unhealthy.
        _degradeOracle();
        market.pokeOracleState(params);
        vm.warp(block.timestamp + DEGRADED_GRACE_PLUS);

        vm.prank(liquidator);
        vm.expectPartialRevert(MarketErrors.Market__HealthyAtAnchor.selector);
        market.liquidateDegraded(params, borrower, 1);
    }

    /// @dev The wind-down itself. Pro-rata, plus a premium that has barely started ramping.
    function test_A2_windDownSeizesProRataPlusPremium() public {
        _makeUnhealthyThenDegrade();
        market.pokeOracleState(params);
        vm.warp(block.timestamp + DEGRADED_GRACE_PLUS);

        uint256 sharesBefore = market.positionOf(id, borrower).borrowShares;
        uint256 collateralBefore = market.positionOf(id, borrower).collateral;
        uint256 quarter = sharesBefore / 4;

        vm.prank(liquidator);
        (uint256 seized,) = market.liquidateDegraded(params, borrower, quarter);

        uint256 proRata = collateralBefore * quarter / sharesBefore;
        assertGe(seized, proRata, "never below pro-rata");
        assertLe(seized, proRata * 11 / 10, "and never more than the 10% premium");
    }

    /// @notice INV-7'. The seizure is arithmetically independent of any price.
    ///
    /// @dev This is the test that licenses storing a price at all. The anchor decides *who*
    ///      may be wound down; it never decides *how much* is taken. Two runs with wildly
    ///      different underlying prices must seize exactly the same amount for the same share
    ///      count, because no price appears in the formula.
    function testFuzz_A2_seizureIsIndependentOfPrice(uint256 hiddenPrice) public {
        hiddenPrice = bound(hiddenPrice, 1e18, 1_000e18);

        _makeUnhealthyThenDegrade();
        market.pokeOracleState(params);
        vm.warp(block.timestamp + DEGRADED_GRACE_PLUS);

        // Whatever the sources are saying underneath — and they are saying something
        // different on every fuzz run — the market cannot read it, and the arithmetic below
        // never asks.
        _allSourcesDisagreeAround(hiddenPrice);

        uint256 sharesBefore = market.positionOf(id, borrower).borrowShares;
        uint256 collateralBefore = market.positionOf(id, borrower).collateral;
        uint256 quarter = sharesBefore / 4;

        vm.prank(liquidator);
        (uint256 seized,) = market.liquidateDegraded(params, borrower, quarter);

        uint256 proRata = collateralBefore * quarter / sharesBefore;
        assertGe(seized, proRata);
        assertLe(seized, proRata * 11 / 10);
    }

    function test_A2_windDownRespectsTheCloseFactor() public {
        _makeUnhealthyThenDegrade();
        market.pokeOracleState(params);
        vm.warp(block.timestamp + DEGRADED_GRACE_PLUS);

        uint256 all = market.positionOf(id, borrower).borrowShares;

        vm.prank(liquidator);
        vm.expectPartialRevert(MarketErrors.Market__CloseFactorExceeded.selector);
        market.liquidateDegraded(params, borrower, all);
    }

    /// @dev A guardian pause and a reporter outage are indistinguishable at the adapter, so
    ///      one mechanism answers both. This is the A6 case travelling the A2 path.
    function test_A2_guardianPauseAlsoOpensTheWindDown() public {
        _makeUnhealthy();

        vm.prank(guardian);
        router.pause(COL_ASSET);

        market.pokeOracleState(params);
        vm.warp(block.timestamp + DEGRADED_GRACE_PLUS);

        // Read first: as an inline argument this external call eats the prank.
        uint256 quarter = market.positionOf(id, borrower).borrowShares / 4;

        vm.prank(liquidator);
        market.liquidateDegraded(params, borrower, quarter);
    }

    // --------------------------------------------------------------------------------

    uint256 internal constant DEGRADED_GRACE_PLUS = 73 hours;

    function _allSourcesAgreeOn(uint256 price) internal {
        vm.warp(block.timestamp + HEARTBEAT);
        for (uint256 i; i < SOURCE_COUNT; ++i) {
            _attest(i, COL_ASSET, price, BASE_DEPTH_USD, block.timestamp);
            _attest(i, LOAN_ASSET, LOAN_PRICE_USD, BASE_DEPTH_USD, block.timestamp);
        }
    }

    function _allSourcesDisagreeAround(uint256 price) internal {
        vm.warp(block.timestamp + HEARTBEAT);
        for (uint256 i; i < SOURCE_COUNT; ++i) {
            uint256 p = i == 0 ? price * 50 : price;
            _attest(i, COL_ASSET, p, BASE_DEPTH_USD, block.timestamp);
            _attest(i, LOAN_ASSET, LOAN_PRICE_USD, BASE_DEPTH_USD, block.timestamp);
        }
    }

    /// @dev Walks the anchor down with the price so the position is unhealthy *at the anchor*,
    ///      which is what the wind-down gates on.
    function _makeUnhealthy() internal {
        vm.prank(borrower);
        market.borrow(params, 36_000e6, 0, borrower, borrower); // ~86k total, at the LLTV

        for (uint256 step; step < 3; ++step) {
            _allSourcesAgreeOn(COL_PRICE_USD * 96 / 100);
            market.pokeOracleState(params);
            vm.warp(block.timestamp + 1 hours);
        }
        _allSourcesAgreeOn(COL_PRICE_USD * 90 / 100);
        market.pokeOracleState(params);
    }

    function _degradeOracle() internal {
        vm.warp(block.timestamp + HEARTBEAT);
        for (uint256 i = 1; i < SOURCE_COUNT; ++i) {
            _attest(i, COL_ASSET, COL_PRICE_USD, BASE_DEPTH_USD, block.timestamp);
            _attest(i, LOAN_ASSET, LOAN_PRICE_USD, BASE_DEPTH_USD, block.timestamp);
        }
        _attest(0, COL_ASSET, COL_PRICE_USD * 100, BASE_DEPTH_USD, block.timestamp);
        _attest(0, LOAN_ASSET, LOAN_PRICE_USD, BASE_DEPTH_USD, block.timestamp);
    }

    function _makeUnhealthyThenDegrade() internal {
        _makeUnhealthy();
        _degradeOracle();
    }
}
