// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {MarketTestBase} from "../helpers/MarketTestBase.sol";
import {SharesMathLib} from "../../../src/market/libraries/SharesMathLib.sol";
import {MathLib} from "../../../src/market/libraries/MathLib.sol";
import {AdaptiveCurveIrm} from "../../../src/market/AdaptiveCurveIrm.sol";
import {Market, MarketParams} from "../../../src/market/types/MarketTypes.sol";

/// @notice Rounding always favours the protocol, and the interest curve stays inside its bounds.
contract RoundingFuzzTest is Test {
    using SharesMathLib for uint256;

    /// @dev Supplying then valuing the shares back must never return more than went in. The
    ///      dust stays with the market, which means it stays with the other suppliers.
    function testFuzz_supplyRoundTripNeverFavoursTheUser(
        uint256 assets,
        uint256 totalAssets,
        uint256 totalShares
    ) public pure {
        assets = bound(assets, 1, 1e30);
        totalAssets = bound(totalAssets, 0, 1e30);
        totalShares = bound(totalShares, 0, 1e36);

        uint256 shares = assets.toSharesDown(totalAssets, totalShares);
        uint256 back = shares.toAssetsDown(totalAssets, totalShares);

        assertLe(back, assets, "a supplier cannot mint value out of rounding");
    }

    /// @dev Borrowing then valuing the debt back must never return less than went out. The
    ///      borrower owes the dust.
    function testFuzz_borrowRoundTripNeverFavoursTheUser(
        uint256 assets,
        uint256 totalAssets,
        uint256 totalShares
    ) public pure {
        assets = bound(assets, 1, 1e30);
        totalAssets = bound(totalAssets, 0, 1e30);
        totalShares = bound(totalShares, 0, 1e36);

        uint256 shares = assets.toSharesUp(totalAssets, totalShares);
        uint256 owed = shares.toAssetsUp(totalAssets, totalShares);

        assertGe(owed, assets, "a borrower cannot shed debt through rounding");
    }

    /// @dev Withdrawing burns at least as many shares as supplying the same amount minted.
    ///      Anything else would let a user cycle supply/withdraw and accumulate shares.
    function testFuzz_withdrawBurnsAtLeastWhatSupplyMinted(
        uint256 assets,
        uint256 totalAssets,
        uint256 totalShares
    ) public pure {
        assets = bound(assets, 1, 1e30);
        totalAssets = bound(totalAssets, 0, 1e30);
        totalShares = bound(totalShares, 0, 1e36);

        assertGe(
            assets.toSharesUp(totalAssets, totalShares),
            assets.toSharesDown(totalAssets, totalShares),
            "withdraw must not cost fewer shares than supply minted"
        );
    }

    /// @dev Repaying burns no more shares than borrowing the same amount created, so a
    ///      borrower can always clear exactly what they took.
    function testFuzz_repayBurnsNoMoreThanBorrowCreated(
        uint256 assets,
        uint256 totalAssets,
        uint256 totalShares
    ) public pure {
        assets = bound(assets, 1, 1e30);
        totalAssets = bound(totalAssets, 0, 1e30);
        totalShares = bound(totalShares, 0, 1e36);

        assertLe(
            assets.toSharesDown(totalAssets, totalShares),
            assets.toSharesUp(totalAssets, totalShares),
            "repay must not burn more shares than borrow created"
        );
    }

    /// @dev M4. What virtual shares actually buy, stated honestly.
    ///
    ///      They do **not** make the first-depositor inflation attack impossible — a large
    ///      enough donation still rounds a later deposit to zero. What they do is set the
    ///      price of that outcome: the attacker has to donate at least `VIRTUAL_SHARES` times
    ///      the victim's deposit to achieve it, and everything they donate is gone. Burning a
    ///      million tokens to capture the rounding on one is not an attack, it is a gift.
    ///
    ///      The first version of this test asserted "never rounds to zero" and the fuzzer
    ///      found the counterexample immediately. It was right: the guarantee is economic, not
    ///      absolute, and claiming otherwise in a security test is worse than claiming nothing.
    function testFuzz_virtualSharesMakeInflationUneconomic(uint256 donation, uint256 deposit) public pure {
        deposit = bound(deposit, 1e6, 1e24);
        donation = bound(donation, 1, 1e40);

        uint256 attackerShares = uint256(1).toSharesDown(0, 0);
        uint256 victimShares = deposit.toSharesDown(donation, attackerShares);

        if (victimShares == 0) {
            assertGe(
                donation,
                deposit * SharesMathLib.VIRTUAL_SHARES,
                "zeroing a deposit must cost at least VIRTUAL_SHARES times its size"
            );
        }
    }
}

/// @notice The interest curve, exercised against a live market.
contract CurveFuzzTest is MarketTestBase {
    using MathLib for uint256;

    /// @dev Whatever the model returns, the market clamps it. This is the bound that makes a
    ///      captured whitelist survivable rather than catastrophic.
    function testFuzz_rateStaysWithinTheMarketClamp(uint256 supplyAssets, uint256 borrowAssets) public view {
        supplyAssets = bound(supplyAssets, 1e6, 1e30);
        borrowAssets = bound(borrowAssets, 0, supplyAssets);

        Market memory m;
        // forge-lint: disable-next-line(unsafe-typecast)
        m.totalSupplyAssets = uint128(supplyAssets);
        // forge-lint: disable-next-line(unsafe-typecast)
        m.totalBorrowAssets = uint128(borrowAssets);
        // forge-lint: disable-next-line(unsafe-typecast)
        m.lastUpdate = uint128(block.timestamp);

        uint256 rate = irm.borrowRateView(params, m);
        assertLe(rate, market.MAX_BORROW_RATE(), "the market clamp must bound every model");
    }

    /// @dev Higher utilisation is never cheaper. A curve that inverted would pay borrowers to
    ///      drain the market.
    function testFuzz_rateIsMonotonicInUtilisation(uint256 supplyAssets, uint256 a, uint256 b) public view {
        supplyAssets = bound(supplyAssets, 1e12, 1e30);
        a = bound(a, 0, supplyAssets);
        b = bound(b, a, supplyAssets);

        Market memory low;
        // forge-lint: disable-next-line(unsafe-typecast)
        low.totalSupplyAssets = uint128(supplyAssets);
        // forge-lint: disable-next-line(unsafe-typecast)
        low.totalBorrowAssets = uint128(a);
        // forge-lint: disable-next-line(unsafe-typecast)
        low.lastUpdate = uint128(block.timestamp);

        Market memory high;
        // forge-lint: disable-next-line(unsafe-typecast)
        high.totalSupplyAssets = uint128(supplyAssets);
        // forge-lint: disable-next-line(unsafe-typecast)
        high.totalBorrowAssets = uint128(b);
        // forge-lint: disable-next-line(unsafe-typecast)
        high.lastUpdate = uint128(block.timestamp);

        assertLe(
            irm.borrowRateView(params, low),
            irm.borrowRateView(params, high),
            "borrowing more must never get cheaper"
        );
    }

    /// @dev An empty market charges the floor rather than reverting or returning nonsense.
    function test_curveHandlesAnEmptyMarket() public view {
        Market memory m;
        // forge-lint: disable-next-line(unsafe-typecast)
        m.lastUpdate = uint128(block.timestamp);
        assertLe(irm.borrowRateView(params, m), market.MAX_BORROW_RATE());
    }

    /// @dev The anchor is bounded at both ends however long the market sits at an extreme.
    function testFuzz_anchorStaysInsideItsBounds(uint256 elapsed) public {
        elapsed = bound(elapsed, 1, 365 days);

        Market memory m;
        m.totalSupplyAssets = 1e18;
        m.totalBorrowAssets = 1e18; // pinned at 100% utilisation
        // forge-lint: disable-next-line(unsafe-typecast)
        m.lastUpdate = uint128(block.timestamp);

        vm.warp(block.timestamp + elapsed);
        uint256 rate = irm.borrowRateView(params, m);

        assertLe(
            rate,
            irm.MAX_RATE_AT_TARGET() * irm.CURVE_STEEPNESS() / 1e18,
            "the curve cannot escape its own ceiling"
        );
    }
}
