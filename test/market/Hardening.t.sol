// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {MarketTestBase} from "./helpers/MarketTestBase.sol";
import {RevertingIrm, GasBombIrm, ReentrantIrm} from "./helpers/HostileIrm.sol";
import {CotejoMarket} from "../../src/market/CotejoMarket.sol";
import {AdaptiveCurveIrm} from "../../src/market/AdaptiveCurveIrm.sol";
import {CotejoOracleAdapter} from "../../src/market/CotejoOracleAdapter.sol";
import {Id, MarketParams} from "../../src/market/types/MarketTypes.sol";
import {MarketErrors} from "../../src/market/libraries/MarketErrors.sol";

/// @notice The defences added after the threat model was written, each against the attack it
///         exists for.
contract HardeningTest is MarketTestBase {
    uint256 internal constant SUPPLY = 3_000_000e6;

    // --------------------------------------------------------------------------------
    // A5.1 — a hostile IRM must not be able to freeze a market
    // --------------------------------------------------------------------------------

    /// @dev The severe case. Before the gas-capped `try/catch`, a reverting model bricked
    ///      every path including `repay` and `liquidate`, and `irm` being part of the `Id`
    ///      meant de-whitelisting could not rescue the market. Funds would have been stranded
    ///      permanently.
    function test_A5_revertingIrmDoesNotFreezeTheMarket() public {
        (MarketParams memory p, Id pid) = _marketWithIrm(address(new RevertingIrm()));

        vm.prank(supplier);
        market.supply(p, SUPPLY, 0, supplier);
        _postCollateral2(p, borrower, 1_000e18);
        _borrow2(p, borrower, 50_000e6);

        vm.warp(block.timestamp + 1 days);
        _refresh(0);

        // A whole day at a reverting IRM accrued exactly nothing — not junk, not a freeze.
        assertEq(market.marketOf(pid).totalBorrowAssets, 50_000e6, "a failed IRM accrues zero interest");

        // The escape hatch survives, which is the property that actually matters: before the
        // gas-capped try/catch this call reverted forever and the funds were stranded.
        uint256 before = market.positionOf(pid, borrower).borrowShares;
        vm.prank(borrower);
        market.repay(p, 10_000e6, 0, borrower);
        assertLt(market.positionOf(pid, borrower).borrowShares, before, "repay must survive");
        assertEq(market.marketOf(pid).totalBorrowAssets, 40_000e6, "and the repay landed exactly");
    }

    function test_A5_gasBombIrmIsContained() public {
        (MarketParams memory p, Id pid) = _marketWithIrm(address(new GasBombIrm()));

        vm.prank(supplier);
        market.supply(p, SUPPLY, 0, supplier);
        _postCollateral2(p, borrower, 1_000e18);
        _borrow2(p, borrower, 50_000e6);

        vm.warp(block.timestamp + 1 days);
        _refresh(0);

        vm.prank(borrower);
        market.repay(p, 1_000e6, 0, borrower);
        assertGt(market.marketOf(pid).totalBorrowAssets, 0, "market still operates");
    }

    /// @dev A5.2. The reentrant attempt is stopped by the guard, the resulting revert is
    ///      absorbed by the IRM `catch`, and the market proceeds with zero interest for that
    ///      interval. Two layers, and the attacker gets neither a freeze nor a reentry.
    function test_A5_reentrantIrmIsBlocked() public {
        ReentrantIrm rogue = new ReentrantIrm(address(market));
        (MarketParams memory p,) = _marketWithIrm(address(rogue));

        vm.prank(supplier);
        market.supply(p, SUPPLY, 0, supplier);
        _postCollateral2(p, borrower, 1_000e18);

        rogue.arm(p);

        vm.prank(borrower);
        market.borrow(p, 10_000e6, 0, borrower, borrower);

        assertEq(loan.balanceOf(borrower), 10_000e6, "the honest borrow completed exactly once");
    }

    // --------------------------------------------------------------------------------
    // F2 — the depth ceiling binds across every market sharing an adapter
    // --------------------------------------------------------------------------------

    /// @dev `createMarket` is permissionless and `lltv` is part of the `Id`, so without an
    ///      adapter-level aggregate anyone could mint a second market over the same routes and
    ///      hand it a second full ceiling against the same order book. The cap would have been
    ///      defeated by arithmetic, without touching the oracle at all.
    function test_F2_secondMarketCannotDoubleTheDepthCeiling() public {
        _supply(SUPPLY);
        _postCollateral(borrower, 30_000e18);

        // Market A draws most of the shared 2M ceiling.
        _borrow(borrower, 1_800_000e6);

        // Market B: same adapter, same tokens, different LLTV — a different `Id` entirely.
        MarketParams memory b = params;
        b.lltv = 0.8e18;
        Id bid = market.createMarket(b, LIF);

        vm.prank(supplier);
        market.supply(b, SUPPLY, 0, supplier);
        vm.prank(borrower);
        market.supplyCollateral(b, 30_000e18, borrower);

        assertEq(
            market.adapterTotalBorrow(address(adapter)),
            market.marketOf(id).totalBorrowAssets,
            "the aggregate sees market A"
        );

        // 1.8M + 0.5M would be 2.3M against a 2M shared ceiling.
        vm.prank(borrower);
        vm.expectPartialRevert(MarketErrors.Market__DepthCapExceeded.selector);
        market.borrow(b, 500_000e6, 0, borrower, borrower);

        // A small borrow that keeps the total under the ceiling is still fine.
        vm.prank(borrower);
        market.borrow(b, 100_000e6, 0, borrower, borrower);

        assertGt(market.marketOf(bid).totalBorrowAssets, 0);
        assertLe(
            market.adapterTotalBorrow(address(adapter)),
            market.maxTotalBorrow(params),
            "the shared ceiling holds across both markets"
        );
    }

    function test_F2_adapterMarketCountIsBounded() public {
        // The baseline market is already one of the eight.
        for (uint256 i = 1; i < market.MAX_MARKETS_PER_ADAPTER(); ++i) {
            MarketParams memory p = params;
            p.lltv = 0.86e18 - (i * 1e16);
            market.createMarket(p, LIF);
        }

        MarketParams memory overflow = params;
        overflow.lltv = 0.5e18;
        vm.expectPartialRevert(MarketErrors.Market__TooManyMarketsPerAdapter.selector);
        market.createMarket(overflow, LIF);
    }

    // --------------------------------------------------------------------------------
    // D1 — the growth clamp must not decay over a quiet period
    // --------------------------------------------------------------------------------

    /// @dev The anchor used to advance only on `borrow`, and `elapsed` was uncapped. After a
    ///      quiet week the permitted growth was ~42x the anchor, which is no clamp at all.
    function test_D1_clampSurvivesAQuietWeek() public {
        _supply(SUPPLY);
        _postCollateral(borrower, 10_000e18);
        _borrow(borrower, 100_000e6); // anchors depth at 4M

        // A week passes with no borrowing, then every reporter claims ten times the depth.
        vm.warp(block.timestamp + 7 days);
        for (uint256 i; i < SOURCE_COUNT; ++i) {
            _attest(i, COL_ASSET, COL_PRICE_USD, BASE_DEPTH_USD * 10, block.timestamp);
            _attest(i, LOAN_ASSET, LOAN_PRICE_USD, BASE_DEPTH_USD * 10, block.timestamp);
        }

        // elapsed is credited at DEPTH_CLAMP_MAX_ELAPSED (4h), so growth is capped at 100%:
        // 4M -> 8M, and the ceiling is half of that.
        assertEq(market.maxTotalBorrow(params), 4_000_000e6, "one refresh can at most double it");
        assertLt(market.maxTotalBorrow(params), 20_000_000e6, "the unclamped claim would have been 20M");
    }

    /// @dev Anyone can keep the anchor current, which is what stops it going stale between
    ///      borrows in the first place.
    function test_D1_pokeIsPermissionlessAndAdvancesTheAnchor() public {
        _supply(SUPPLY);
        _postCollateral(borrower, 10_000e18);
        _borrow(borrower, 100_000e6);

        _refreshWithDepth(BASE_DEPTH_USD / 4);

        vm.prank(stranger());
        market.pokeDepthAnchor(params);

        assertEq(market.maxTotalBorrow(params), 500_000e6, "the fall is now recorded");
    }

    // --------------------------------------------------------------------------------
    // A1.1 — the ceiling that does not trust any reporter
    // --------------------------------------------------------------------------------

    /// @dev The load-bearing defence against a colluding reporter set: it binds regardless of
    ///      what anyone reports, so total collusion buys a bounded loss rather than an
    ///      unbounded one.
    function test_A1_hardCeilingBindsBelowTheReportedDepth() public {
        CotejoMarket tight = new CotejoMarket(owner, DEPTH_MULTIPLIER_BPS, 250_000);
        AdaptiveCurveIrm tightIrm = new AdaptiveCurveIrm(address(tight));
        vm.prank(owner);
        tight.proposeIrm(address(tightIrm));
        vm.warp(block.timestamp + tight.IRM_TIMELOCK());
        tight.executeIrm(address(tightIrm));
        _refresh(0);

        MarketParams memory p = params;
        p.irm = address(tightIrm);
        tight.createMarket(p, LIF);

        // Reporters claim 4M of depth, which would support a 2M ceiling. The immutable says
        // 250k, and the immutable wins.
        assertEq(tight.maxTotalBorrow(p), 250_000e6, "the report-independent ceiling binds");
    }

    function test_A1_ratchetLowersTheCeilingAndCannotRaiseIt() public {
        _supply(SUPPLY);
        _postCollateral(borrower, 10_000e18);
        _borrow(borrower, 200_000e6);

        vm.prank(owner);
        market.ratchetDebtCeiling(id, 250_000e6);
        assertEq(market.hardCeilingOf(id), 250_000e6);

        vm.prank(borrower);
        vm.expectPartialRevert(MarketErrors.Market__DebtCeilingExceeded.selector);
        market.borrow(params, 100_000e6, 0, borrower, borrower);

        // Only ever downwards. There is no companion function that raises one.
        vm.prank(owner);
        vm.expectPartialRevert(MarketErrors.Market__CeilingNotDecreasing.selector);
        market.ratchetDebtCeiling(id, 500_000e6);
    }

    /// @dev The ratchet must never touch solvency control: it blocks new borrowing and leaves
    ///      liquidation alone. That asymmetry is what lets it skip a timelock.
    function test_A1_ratchetDoesNotAffectLiquidation() public {
        _supply(SUPPLY);
        _postCollateral(borrower, 1_000e18);
        _borrow(borrower, 80_000e6);

        vm.prank(owner);
        market.ratchetDebtCeiling(id, 1);

        _crashCollateralPrice(50e18);

        vm.prank(liquidator);
        market.liquidate(params, borrower, 100e18, 0);
        assertLt(market.positionOf(id, borrower).collateral, 1_000e18, "liquidation still works");
    }

    // --------------------------------------------------------------------------------
    // A1.2 / A4 — bad debt feeds back into the ceiling, and insolvency allows a full close
    // --------------------------------------------------------------------------------

    /// @dev Bad debt is on-chain proof that the claimed depth was not there — a liquidator
    ///      could not clear the position against the book that was supposed to exist.
    function test_A1_badDebtHaircutsTheDepthAnchor() public {
        _supply(SUPPLY);
        _postCollateral(borrower, 1_000e18);
        _borrow(borrower, 85_000e6);

        uint256 capBefore = market.maxTotalBorrow(params);

        _crashCollateralPrice(50e18);

        // Seize everything: debt now exceeds collateral value, so A4 permits a full close and
        // the remainder becomes bad debt.
        vm.prank(liquidator);
        market.liquidate(params, borrower, 1_000e18, 0);

        assertEq(market.positionOf(id, borrower).borrowShares, 0, "position closed out");
        assertGt(market.marketOf(id).totalSupplyAssets, 0);
        assertApproxEqRel(market.maxTotalBorrow(params), capBefore / 2, 0.01e18, "the anchor was halved");
    }

    /// @dev A4. Below water, the 50% close factor protects nothing and forces a liquidator to
    ///      pay gas repeatedly against a shrinking, still-underwater target.
    function test_A4_fullCloseAllowedOnlyWhenInsolvent() public {
        _supply(SUPPLY);
        _postCollateral(borrower, 1_000e18);
        _borrow(borrower, 80_000e6);

        // Merely unhealthy, still over-collateralised: the close factor applies.
        _crashCollateralPrice(90e18);
        // Read the shares first: as an inline argument this external call would consume the
        // prank and the expectRevert before `liquidate` was ever reached.
        uint256 fullDebtShares = market.positionOf(id, borrower).borrowShares;

        vm.prank(liquidator);
        vm.expectPartialRevert(MarketErrors.Market__CloseFactorExceeded.selector);
        market.liquidate(params, borrower, 0, fullDebtShares);

        // Genuinely insolvent: a single close is allowed.
        _crashCollateralPrice(40e18);
        vm.prank(liquidator);
        market.liquidate(params, borrower, 1_000e18, 0);
        assertEq(market.positionOf(id, borrower).collateral, 0);
    }

    // --------------------------------------------------------------------------------

    function stranger() internal returns (address) {
        return makeAddr("poker");
    }

    function _marketWithIrm(address rogueIrm) internal returns (MarketParams memory p, Id pid) {
        _whitelistIrm(rogueIrm);
        // The whitelist timelock warps 48h, which leaves every attestation stale.
        _refresh(0);
        p = params;
        p.irm = rogueIrm;
        pid = market.createMarket(p, LIF);
    }

    function _postCollateral2(MarketParams memory p, address who, uint256 amount) internal {
        vm.prank(who);
        market.supplyCollateral(p, amount, who);
    }

    function _borrow2(MarketParams memory p, address who, uint256 amount) internal {
        vm.prank(who);
        market.borrow(p, amount, 0, who, who);
    }

    /// @dev Every reporter agrees on the new price, so the oracle keeps serving and the crash
    ///      is a real move rather than a disagreement.
    function _crashCollateralPrice(uint256 newPrice) internal {
        vm.warp(block.timestamp + HEARTBEAT);
        for (uint256 i; i < SOURCE_COUNT; ++i) {
            _attest(i, COL_ASSET, newPrice, BASE_DEPTH_USD, block.timestamp);
            _attest(i, LOAN_ASSET, LOAN_PRICE_USD, BASE_DEPTH_USD, block.timestamp);
        }
    }

    function _refreshWithDepth(uint256 depthUsd) internal {
        vm.warp(block.timestamp + HEARTBEAT);
        for (uint256 i; i < SOURCE_COUNT; ++i) {
            _attest(i, COL_ASSET, COL_PRICE_USD, depthUsd, block.timestamp);
            _attest(i, LOAN_ASSET, LOAN_PRICE_USD, depthUsd, block.timestamp);
        }
    }
}
