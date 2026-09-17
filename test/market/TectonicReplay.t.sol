// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {MarketTestBase} from "./helpers/MarketTestBase.sol";
import {MarketErrors} from "../../src/market/libraries/MarketErrors.sol";
import {CotejoErrors} from "../../src/libraries/CotejoErrors.sol";

/// @notice The argument for the whole project, executed.
///
/// @dev On 30 August 2026 Tectonic lost 75M. A collateral with a 20% factor and $1.34M of
///      liquidity was pumped 100x in twenty minutes; the protocol's liquidation and borrow
///      machinery then worked exactly as designed, handing the attacker good assets against
///      inflated garbage. Crypto.com halted the chain.
///
///      This test rebuilds that setup on Cotejo and shows where it stops. The pump happens.
///      One reporter really does publish 100x. What changes is that the oracle refuses to
///      turn that into a price, and the market refuses to act without one.
contract TectonicReplayTest is MarketTestBase {
    uint256 internal constant SUPPLY = 1_000_000e6; // 1M USDW
    uint256 internal constant COLLATERAL = 1_000e18; // 1000 WBT @ $100 = $100k
    uint256 internal constant BORROW = 50_000e6; // 50k USDW, well inside LLTV

    function setUp() public override {
        super.setUp();
        _supply(SUPPLY);
        _postCollateral(attacker, COLLATERAL);
        _borrow(attacker, BORROW);
    }

    function test_TectonicReplay() public {
        uint256 loanBefore = loan.balanceOf(attacker);
        uint256 collateralBefore = collateral.balanceOf(attacker);

        // --- The pump. One compromised reporter, 100x, over twenty minutes. ---
        // The honest four keep publishing on their heartbeat, so nothing goes stale and the
        // only thing that changes is that one source disagrees violently.
        for (uint256 step = 1; step <= 4; ++step) {
            vm.warp(block.timestamp + HEARTBEAT);
            uint256 pumped = COL_PRICE_USD + (COL_PRICE_USD * 99 * step) / 4;
            for (uint256 i = 1; i < SOURCE_COUNT; ++i) {
                _attest(i, COL_ASSET, COL_PRICE_USD, BASE_DEPTH_USD, block.timestamp);
                _attest(i, LOAN_ASSET, LOAN_PRICE_USD, BASE_DEPTH_USD, block.timestamp);
            }
            _attest(0, COL_ASSET, pumped, BASE_DEPTH_USD, block.timestamp);
            _attest(0, LOAN_ASSET, LOAN_PRICE_USD, BASE_DEPTH_USD, block.timestamp);
        }

        // --- (a) The oracle refuses. ---
        (bool healthy, bytes memory err) = market.isOracleHealthy(params);
        assertFalse(healthy, "the router must refuse a set this far apart");
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(bytes4(err), CotejoErrors.Cotejo__DeviationExceeded.selector, "and it must say exactly why");

        // --- (b) The attacker cannot borrow against the inflated collateral. ---
        // This is the step that drained Tectonic. Here it does not reach the accounting.
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(MarketErrors.Market__OracleDegraded.selector, id, err));
        market.borrow(params, 500_000e6, 0, attacker, attacker);

        // --- (c) Liquidation is blocked too, in both directions. ---
        // Deliberate. Liquidating against a manipulated price is the extraction mechanism,
        // not a defence against it.
        vm.prank(liquidator);
        vm.expectRevert(abi.encodeWithSelector(MarketErrors.Market__OracleDegraded.selector, id, err));
        market.liquidate(params, attacker, 100e18, 0);

        // --- (d) No value left the market. ---
        assertEq(loan.balanceOf(attacker), loanBefore, "attacker extracted no loan tokens");
        assertEq(collateral.balanceOf(attacker), collateralBefore, "and lost no collateral");
        assertEq(
            loan.balanceOf(address(market)),
            SUPPLY - BORROW,
            "the market's balance sheet is untouched by the pump"
        );
    }

    /// @dev The escape hatch stays open. A borrower must never be trapped by an outage they
    ///      did not cause, so repaying works throughout.
    function test_TectonicReplay_repayStillWorksWhileDegraded() public {
        _pumpOneSource();

        (bool healthy,) = market.isOracleHealthy(params);
        assertFalse(healthy);

        uint256 sharesBefore = market.positionOf(id, attacker).borrowShares;

        vm.prank(attacker);
        market.repay(params, 10_000e6, 0, attacker);

        assertLt(
            market.positionOf(id, attacker).borrowShares, sharesBefore, "debt must fall even with no price"
        );
    }

    /// @dev Supplying more collateral is also allowed: it can only improve solvency.
    function test_TectonicReplay_topUpCollateralAllowedWhileDegraded() public {
        _pumpOneSource();

        vm.prank(attacker);
        market.supplyCollateral(params, 10e18, attacker);

        assertEq(market.positionOf(id, attacker).collateral, COLLATERAL + 10e18);
    }

    /// @dev But collateral cannot leave while debt is outstanding and solvency is unknowable.
    function test_TectonicReplay_collateralLockedWhileDegraded() public {
        _pumpOneSource();

        vm.prank(attacker);
        vm.expectRevert();
        market.withdrawCollateral(params, 1e18, attacker, attacker);
    }

    /// @dev And suppliers cannot run ahead of a loss that has not been recognised yet.
    function test_TectonicReplay_supplyWithdrawalBlockedWhileDegraded() public {
        _pumpOneSource();

        vm.prank(supplier);
        vm.expectRevert();
        market.withdraw(params, 100_000e6, 0, supplier, supplier);
    }

    /// @dev Once the compromised reporter falls back into line, everything resumes on its own.
    ///      No governance action, no manual unpause.
    function test_TectonicReplay_recoversWhenTheLiarStops() public {
        _pumpOneSource();
        (bool degraded,) = market.isOracleHealthy(params);
        assertFalse(degraded);

        _refresh(HEARTBEAT);

        (bool healthy,) = market.isOracleHealthy(params);
        assertTrue(healthy, "agreement restored, service restored");

        vm.prank(attacker);
        market.borrow(params, 1_000e6, 0, attacker, attacker);
    }

    // --------------------------------------------------------------------------------

    function _pumpOneSource() internal {
        vm.warp(block.timestamp + HEARTBEAT);
        for (uint256 i = 1; i < SOURCE_COUNT; ++i) {
            _attest(i, COL_ASSET, COL_PRICE_USD, BASE_DEPTH_USD, block.timestamp);
            _attest(i, LOAN_ASSET, LOAN_PRICE_USD, BASE_DEPTH_USD, block.timestamp);
        }
        _attest(0, COL_ASSET, COL_PRICE_USD * 100, BASE_DEPTH_USD, block.timestamp);
        _attest(0, LOAN_ASSET, LOAN_PRICE_USD, BASE_DEPTH_USD, block.timestamp);
    }
}
