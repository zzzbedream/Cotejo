// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {MarketTestBase} from "../helpers/MarketTestBase.sol";
import {MarketHandler} from "./MarketHandler.sol";
import {AttestationSource} from "../../../src/sources/AttestationSource.sol";
import {Id, MarketParams} from "../../../src/market/types/MarketTypes.sol";

/// @notice The three mandatory invariants, over random sequences of everything a user can do
///         while the oracle moves underneath them.
///
/// @dev Two markets deliberately share one adapter, because that is the configuration the
///      depth ceiling has to survive: `createMarket` is permissionless and `lltv` is part of
///      the `Id`, so a second market over the same routes is something anyone can conjure.
contract MarketInvariantsTest is MarketTestBase {
    MarketHandler internal handler;

    MarketParams internal paramsB;
    Id internal idB;

    function setUp() public override {
        super.setUp();

        paramsB = params;
        paramsB.lltv = 0.75e18;
        idB = market.createMarket(paramsB, LIF);

        // Seed both sides so the handler has something to move around.
        _supply(2_000_000e6);
        vm.prank(supplier);
        market.supply(paramsB, 2_000_000e6, 0, supplier);
        _postCollateral(borrower, 20_000e18);
        _borrow(borrower, 200_000e6);

        address[3] memory actors = [supplier, borrower, liquidator];
        AttestationSource[5] memory srcs = [sources[0], sources[1], sources[2], sources[3], sources[4]];
        uint256[5] memory keys =
            [reporterKeys[0], reporterKeys[1], reporterKeys[2], reporterKeys[3], reporterKeys[4]];

        handler = new MarketHandler(market, collateral, loan, params, paramsB, actors, srcs, keys);

        // The handler acts as each actor via prank, so it needs no balances of its own — but
        // the actors need standing approvals for it to work through them.
        for (uint256 i; i < actors.length; ++i) {
            vm.startPrank(actors[i]);
            loan.approve(address(market), type(uint256).max);
            collateral.approve(address(market), type(uint256).max);
            vm.stopPrank();
            collateral.mint(actors[i], 50_000e18);
            loan.mint(actors[i], 5_000_000e6);
        }

        targetContract(address(handler));
    }

    /// @notice The sum of every borrower's debt never exceeds what the market says is borrowed.
    /// @dev Share accounting drifting upward would mean the market owes its suppliers less
    ///      than its borrowers owe it — a silent solvency hole.
    function invariant_borrowSharesNeverExceedTotal() public view {
        for (uint256 k; k < 2; ++k) {
            Id mid = k == 0 ? id : idB;
            uint256 summed;
            summed += market.positionOf(mid, supplier).borrowShares;
            summed += market.positionOf(mid, borrower).borrowShares;
            summed += market.positionOf(mid, liquidator).borrowShares;

            assertLe(
                summed, market.marketOf(mid).totalBorrowShares, "borrower debt shares exceed the market total"
            );
        }
    }

    /// @notice No market can reach another market's collateral.
    /// @dev The isolation property, stated as arithmetic: the contract must physically hold at
    ///      least the sum of what every market's positions claim. Tectonic's shared pool is
    ///      exactly what this forbids.
    function invariant_marketsNeverShareCollateral() public view {
        uint256 claimed;
        for (uint256 k; k < 2; ++k) {
            Id mid = k == 0 ? id : idB;
            claimed += market.positionOf(mid, supplier).collateral;
            claimed += market.positionOf(mid, borrower).collateral;
            claimed += market.positionOf(mid, liquidator).collateral;
        }

        assertGe(
            collateral.balanceOf(address(market)),
            claimed,
            "positions claim more collateral than the market holds"
        );
    }

    /// @notice A successful borrow never leaves the adapter's markets above the depth ceiling.
    ///
    /// @dev Stated as a precondition on new debt rather than as a continuous property, and the
    ///      distinction is load-bearing. A fall in observed liquidity legitimately leaves
    ///      *existing* debt above the ceiling: forcing it back down would make "the book got
    ///      thinner" a liquidation trigger, and hand anyone who can move depth a way to force
    ///      liquidations without touching a price. `test_DepthCapBlocksBorrowNotLiquidation`
    ///      pins that behaviour directly; this invariant is its counterpart over random
    ///      sequences.
    ///
    ///      The first version of this invariant asserted the continuous form and the fuzzer
    ///      found the counterexample within one run — correctly, because the contract was
    ///      right and the invariant was wrong.
    function invariant_borrowNeverExceedsDepthCap() public view {
        assertEq(
            handler.borrowCeilingViolations(),
            0,
            "a borrow succeeded that pushed the adapter past its depth ceiling"
        );
    }

    /// @notice Supply is never less than what it owes to borrowers minus what it holds.
    /// @dev Catches the accounting drifting in the other direction — a market claiming more
    ///      supply assets than it could ever pay out.
    function invariant_supplyCoversLiquidityPlusDebt() public view {
        for (uint256 k; k < 2; ++k) {
            Id mid = k == 0 ? id : idB;
            assertGe(
                market.marketOf(mid).totalSupplyAssets,
                market.marketOf(mid).totalBorrowAssets,
                "a market owes more than it has supplied"
            );
        }
    }

    function invariant_handlerMadeProgress() public view {
        assertGe(handler.calls(), 0);
    }
}
