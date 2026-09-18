// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {MarketTestBase} from "./helpers/MarketTestBase.sol";
import {MockERC20, FeeOnTransferERC20} from "./helpers/MockERC20.sol";
import {HugeRateIrm} from "./helpers/HostileIrm.sol";

import {CotejoMarket} from "../../src/market/CotejoMarket.sol";
import {CotejoOracleAdapter} from "../../src/market/CotejoOracleAdapter.sol";
import {AdaptiveCurveIrm} from "../../src/market/AdaptiveCurveIrm.sol";
import {AttestationSource} from "../../src/sources/AttestationSource.sol";
import {CotejoErrors} from "../../src/libraries/CotejoErrors.sol";
import {ICotejoMarket} from "../../src/market/interfaces/ICotejoMarket.sol";
import {IPriceRouter} from "../../src/interfaces/IPriceRouter.sol";
import {MarketErrors} from "../../src/market/libraries/MarketErrors.sol";
import {MathLib} from "../../src/market/libraries/MathLib.sol";
import {Id, MarketParams, Market} from "../../src/market/types/MarketTypes.sol";

/// @notice The paths the rest of the suite never reached.
///
/// @dev These are not exotic cases. They are argument validation, the shares-denominated half
///      of every user-facing entry point, the administrative surface, and two defences that
///      the threat model describes at length and that no test had ever executed — M5's rate
///      clamp and M6's balance-delta check.
///
///      That last pair is the reason this file exists rather than a coverage percentage. A
///      documented defence with no test behind it is a claim, and `CotejoMarket` is the
///      contract that holds the money.
contract CoverageGapsTest is MarketTestBase {
    using MathLib for uint256;

    // --------------------------------------------------------------------------------
    // Shared guards: _requireCreated and _requireExactlyOne
    // --------------------------------------------------------------------------------

    /// @dev `lltv` is part of the `Id`, so changing it alone names a market that was never
    ///      created — which is the realistic shape of this mistake, not a random hash.
    function _uncreatedParams() internal view returns (MarketParams memory p) {
        p = params;
        p.lltv = 0.5e18;
    }

    function test_rejectsCallsAgainstAMarketThatWasNeverCreated() public {
        MarketParams memory ghost = _uncreatedParams();
        Id ghostId = market.idOf(ghost);

        vm.expectRevert(abi.encodeWithSelector(MarketErrors.Market__NotCreated.selector, ghostId));
        market.supply(ghost, 1e6, 0, supplier);

        vm.expectRevert(abi.encodeWithSelector(MarketErrors.Market__NotCreated.selector, ghostId));
        market.supplyCollateral(ghost, 1e18, borrower);

        vm.expectRevert(abi.encodeWithSelector(MarketErrors.Market__NotCreated.selector, ghostId));
        market.accrueInterest(ghost);
    }

    /// @dev `_requireExactlyOne` has exactly two failing shapes and both collapse to the same
    ///      predicate, `(a == 0) == (b == 0)`. Asking for nothing and asking for two different
    ///      amounts of the same thing are both incoherent, and the contract refuses to guess.
    function test_rejectsBothZeroAndBothNonZero() public {
        vm.startPrank(supplier);

        vm.expectRevert(MarketErrors.Market__InconsistentInput.selector);
        market.supply(params, 0, 0, supplier);

        vm.expectRevert(MarketErrors.Market__InconsistentInput.selector);
        market.supply(params, 1e6, 1e6, supplier);

        vm.stopPrank();
    }

    function test_rejectsZeroAddressOnEveryEntryPointThatTakesOne() public {
        vm.expectRevert(MarketErrors.Market__InvalidParameter.selector);
        market.supply(params, 1e6, 0, address(0));

        vm.expectRevert(MarketErrors.Market__InvalidParameter.selector);
        market.supplyCollateral(params, 1e18, address(0));

        vm.expectRevert(MarketErrors.Market__InvalidParameter.selector);
        market.withdraw(params, 1e6, 0, supplier, address(0));

        vm.expectRevert(MarketErrors.Market__InvalidParameter.selector);
        market.withdrawCollateral(params, 1e18, borrower, address(0));

        vm.expectRevert(MarketErrors.Market__InvalidParameter.selector);
        market.borrow(params, 1e6, 0, borrower, address(0));
    }

    function test_rejectsZeroCollateralAmounts() public {
        vm.expectRevert(MarketErrors.Market__ZeroAssets.selector);
        market.supplyCollateral(params, 0, borrower);

        vm.expectRevert(MarketErrors.Market__ZeroAssets.selector);
        market.withdrawCollateral(params, 0, borrower, borrower);
    }

    // --------------------------------------------------------------------------------
    // createMarket argument validation
    // --------------------------------------------------------------------------------

    function test_createMarketRejectsMalformedParameters() public {
        MarketParams memory p = params;

        p.collateralToken = address(0);
        vm.expectRevert(MarketErrors.Market__InvalidParameter.selector);
        market.createMarket(p, LIF);

        p = params;
        p.loanToken = address(0);
        vm.expectRevert(MarketErrors.Market__InvalidParameter.selector);
        market.createMarket(p, LIF);

        p = params;
        p.oracleAdapter = address(0);
        vm.expectRevert(MarketErrors.Market__InvalidParameter.selector);
        market.createMarket(p, LIF);

        // A market whose collateral and loan token are the same asset has no solvency
        // question to answer: the ratio is constant and liquidation is meaningless.
        p = params;
        p.loanToken = params.collateralToken;
        vm.expectRevert(MarketErrors.Market__InvalidParameter.selector);
        market.createMarket(p, LIF);

        // `lltv == 0` passes the R3 ceiling but makes every position instantly liquidatable.
        p = params;
        p.lltv = 0;
        vm.expectRevert(MarketErrors.Market__InvalidParameter.selector);
        market.createMarket(p, LIF);
    }

    /// @dev An incentive below `WAD` pays a liquidator less than the debt they clear, so
    ///      nobody liquidates and the market has no solvency mechanism at all. R5 bounds the
    ///      incentive from above; this is the floor it needs underneath.
    function test_createMarketRejectsIncentiveBelowOne() public {
        MarketParams memory p = params;
        p.lltv = 0.8e18; // distinct Id, otherwise AlreadyCreated fires first

        vm.expectRevert(MarketErrors.Market__InvalidParameter.selector);
        market.createMarket(p, WAD_MINUS_ONE);
    }

    uint256 internal constant WAD_MINUS_ONE = 1e18 - 1;

    // --------------------------------------------------------------------------------
    // Shares-denominated paths
    // --------------------------------------------------------------------------------

    /// @dev Every entry point accepts either assets or shares, and until now the suite only
    ///      ever passed assets. The shares branch is the one an integrating contract uses when
    ///      it wants to close a position exactly, so it is the branch where a rounding error
    ///      would be found by a user rather than by a test.
    function test_supplyAndWithdrawDenominatedInShares() public {
        uint256 seed = 1_000 * 10 ** LOAN_DECIMALS;
        _supply(seed);

        uint256 sharesBefore = market.positionOf(id, supplier).supplyShares;

        vm.prank(supplier);
        (uint256 assetsIn, uint256 sharesIn) = market.supply(params, 0, sharesBefore, supplier);

        assertEq(sharesIn, sharesBefore, "supply by shares must mint exactly what was asked");
        assertEq(
            market.positionOf(id, supplier).supplyShares,
            sharesBefore * 2,
            "position must hold both deposits"
        );
        // Supplying by shares rounds the asset cost up, so the protocol never mints shares
        // that were underpaid for.
        assertGe(assetsIn, seed, "asset cost of shares must round in the pool's favour");

        vm.prank(supplier);
        (uint256 assetsOut, uint256 sharesOut) = market.withdraw(params, 0, sharesIn, supplier, supplier);

        assertEq(sharesOut, sharesIn, "withdraw by shares must burn exactly what was asked");
        // And withdrawing by shares rounds the payout down, for the same reason in reverse.
        assertLe(assetsOut, assetsIn, "round trip through shares must not pay out more than it took in");
    }

    function test_borrowAndRepayDenominatedInShares() public {
        _supply(100_000 * 10 ** LOAN_DECIMALS);
        _postCollateral(borrower, 1_000e18);

        // Borrow by shares. With no debt outstanding the conversion is the virtual-share
        // ratio, so this also exercises the first-borrow path of `toAssetsDown`.
        uint256 wantShares = 1_000 * 10 ** LOAN_DECIMALS * 1e6;

        vm.prank(borrower);
        (uint256 assetsOut, uint256 sharesOut) = market.borrow(params, 0, wantShares, borrower, borrower);

        assertEq(sharesOut, wantShares, "borrow by shares must issue exactly what was asked");
        assertGt(assetsOut, 0, "borrowing shares must hand over assets");
        assertEq(market.positionOf(id, borrower).borrowShares, wantShares, "debt must be recorded in shares");

        // Repay the whole position by shares. This is the path that lets a borrower exit
        // exactly, with no dust left behind by an assets-denominated estimate.
        vm.prank(borrower);
        (uint256 assetsIn, uint256 sharesIn) = market.repay(params, 0, wantShares, borrower);

        assertEq(sharesIn, wantShares, "repay by shares must burn exactly what was asked");
        assertGe(assetsIn, assetsOut, "repaying shares must cost at least what borrowing them paid");
        assertEq(market.positionOf(id, borrower).borrowShares, 0, "position must close exactly");
    }

    // --------------------------------------------------------------------------------
    // M6 — the balance-delta check
    // --------------------------------------------------------------------------------

    /// @notice A token that starts honest and later charges a transfer fee is refused at the
    ///         moment it lies, not absorbed into the accounting.
    ///
    /// @dev R6 binds `assetId -> token` at market creation, so a fee-on-transfer token cannot
    ///      be admitted as a surprise. The residual risk M6 exists for is the token that
    ///      passes admission and changes afterwards — an upgradeable token turning a fee on.
    ///      `vm.etch` is exactly that: the address, the balances and the allowances are
    ///      untouched, and only the code behind them changes.
    ///
    ///      The swap is layout-safe because `FeeOnTransferERC20` extends `MockERC20` and adds
    ///      one `constant`, which occupies no storage. `decimals` is `immutable` and therefore
    ///      lives in the code being replaced, so the replacement is constructed with the same
    ///      value.
    ///
    ///      Without M6 the market would credit the borrower the full amount, hold less than
    ///      that, and the shortfall would surface much later as unattributable bad debt.
    function test_feeOnTransferTokenIsRejectedAtTheMomentItStartsLying() public {
        uint256 amount = 100e18;

        // Honest first: the same call succeeds before the code is swapped, so the revert
        // below is caused by the fee and nothing else.
        _postCollateral(borrower, amount);

        FeeOnTransferERC20 cheat = new FeeOnTransferERC20("Whitechain Token", "WBT", COL_DECIMALS);
        vm.etch(address(collateral), address(cheat).code);

        uint256 fee = amount * cheat.FEE_BPS() / 10_000;

        vm.prank(borrower);
        vm.expectRevert(
            abi.encodeWithSelector(
                MarketErrors.Market__UnexpectedBalanceDelta.selector,
                address(collateral),
                amount,
                amount - fee
            )
        );
        market.supplyCollateral(params, amount, borrower);
    }

    // --------------------------------------------------------------------------------
    // M5 — the interest rate clamp
    // --------------------------------------------------------------------------------

    /// @notice A whitelisted model that answers with an absurd rate is clamped, not obeyed.
    ///
    /// @dev `RevertingIrm` and `GasBombIrm` cover the models that fail loudly. This covers the
    ///      one that does not: a captured model that returns 100% per second is a perfectly
    ///      well-formed answer, passes the `try/catch` untouched, and reaches the accrual
    ///      arithmetic. M5 is the only thing between it and a market whose debt doubles every
    ///      second. The threat model has claimed that bound since phase 2; this executes it.
    function test_absurdBorrowRateIsClampedToTheCeiling() public {
        HugeRateIrm huge = new HugeRateIrm();
        _whitelistIrm(address(huge));
        // `_whitelistIrm` warps through the 48h timelock, which leaves every attestation
        // stale. Re-publish before anything needs a price.
        _seedPrices(COL_PRICE_USD, LOAN_PRICE_USD, BASE_DEPTH_USD);

        MarketParams memory p = params;
        p.irm = address(huge);
        Id hugeId = market.createMarket(p, LIF);

        vm.prank(supplier);
        market.supply(p, 100_000 * 10 ** LOAN_DECIMALS, 0, supplier);
        vm.prank(borrower);
        market.supplyCollateral(p, 1_000e18, borrower);
        vm.prank(borrower);
        market.borrow(p, 1_000 * 10 ** LOAN_DECIMALS, 0, borrower, borrower);

        uint256 borrowBefore = market.marketOf(hugeId).totalBorrowAssets;
        uint256 elapsed = 1 hours;
        vm.warp(block.timestamp + elapsed);

        market.accrueInterest(p);

        uint256 accrued = market.marketOf(hugeId).totalBorrowAssets - borrowBefore;
        uint256 atTheCap = borrowBefore.wMulDown(market.MAX_BORROW_RATE().wTaylorCompounded(elapsed));

        assertEq(accrued, atTheCap, "interest must accrue at exactly MAX_BORROW_RATE, not the model's rate");

        // What the clamp is worth, stated as a ratio rather than left implicit: the model
        // asked for a rate about four million times the ceiling.
        assertGt(huge.RATE() / market.MAX_BORROW_RATE(), 1_000_000, "the clamp must be doing real work here");
    }

    /// @dev The other half of the same defence. `borrowRate` is not `view` and may keep state,
    ///      so a caller who is not the market could otherwise drive the adaptive curve's
    ///      anchor wherever they liked before a real accrual reads it.
    function test_irmRefusesCallersOtherThanItsMarket() public {
        Market memory snapshot = market.marketOf(id);

        vm.prank(attacker);
        vm.expectRevert(MarketErrors.Market__InvalidParameter.selector);
        irm.borrowRate(params, snapshot);
    }

    // --------------------------------------------------------------------------------
    // Administrative surface
    // --------------------------------------------------------------------------------

    function test_proposeIrmRejectsMalformedAndDuplicateProposals() public {
        address fresh = address(new HugeRateIrm());

        vm.startPrank(owner);

        vm.expectRevert(MarketErrors.Market__InvalidParameter.selector);
        market.proposeIrm(address(0));

        // Already whitelisted: re-proposing would restart a timelock for a power already held.
        vm.expectRevert(MarketErrors.Market__InvalidParameter.selector);
        market.proposeIrm(address(irm));

        market.proposeIrm(fresh);
        assertEq(market.pendingIrm(fresh), uint64(block.timestamp + market.IRM_TIMELOCK()), "eta must be readable");

        // Already pending: re-proposing would otherwise be a way to keep the eta moving.
        vm.expectRevert(MarketErrors.Market__InvalidParameter.selector);
        market.proposeIrm(fresh);

        vm.stopPrank();
    }

    function test_executeIrmRejectsUnproposedAndEarlyCalls() public {
        address fresh = address(new HugeRateIrm());

        vm.expectRevert(MarketErrors.Market__InvalidParameter.selector);
        market.executeIrm(fresh);

        vm.prank(owner);
        market.proposeIrm(fresh);
        uint64 eta = market.pendingIrm(fresh);

        vm.warp(eta - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                MarketErrors.Market__IrmTimelockNotElapsed.selector, fresh, eta, block.timestamp
            )
        );
        market.executeIrm(fresh);

        // Execution is permissionless once the wait is over: the delay is the control, not
        // who ends it.
        vm.warp(eta);
        vm.prank(attacker);
        market.executeIrm(fresh);
        assertTrue(market.isIrmWhitelisted(fresh), "the timelock, not the caller, is the gate");
    }

    /// @dev Revocation is immediate and clears any pending proposal with it. A withdrawal of
    ///      capability can only ever restrict, so making it wait would be the dangerous
    ///      choice, not the safe one.
    function test_revokeIrmIsImmediateAndClearsAnyPendingProposal() public {
        address fresh = address(new HugeRateIrm());

        vm.prank(owner);
        market.proposeIrm(fresh);
        assertGt(market.pendingIrm(fresh), 0, "proposal must be pending before revoking it");

        vm.prank(owner);
        market.revokeIrm(fresh);

        assertEq(market.pendingIrm(fresh), 0, "revoking must cancel the pending proposal too");
        assertFalse(market.isIrmWhitelisted(fresh), "revoked model must not be whitelisted");

        // Revoking the live model does not touch markets that already exist: `irm` is baked
        // into the `Id`, which is exactly why R4 is a creation-time check.
        vm.prank(owner);
        market.revokeIrm(address(irm));
        assertFalse(market.isIrmWhitelisted(address(irm)), "revocation must apply to the live model too");

        market.accrueInterest(params);
    }

    function test_irmAdministrationIsOwnerOnly() public {
        // Deployed before the expectation, not inside the call. `new` is an external call and
        // `vm.expectRevert` binds to the next one, so writing it inline consumes the
        // expectation on the CREATE and the test passes while proving nothing.
        address fresh = address(new HugeRateIrm());

        vm.startPrank(attacker);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        market.proposeIrm(fresh);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        market.revokeIrm(address(irm));

        vm.stopPrank();
    }

    /// @dev The ceiling is monotonically decreasing, which is what lets it live without a
    ///      timelock. Both halves of that claim are asserted here: a lower value lands, and an
    ///      equal or higher one is refused.
    function test_debtCeilingOnlyRatchetsDown() public {
        uint256 start = market.hardCeilingOf(id);
        assertEq(start, type(uint128).max, "a new market must start unbounded");

        vm.prank(owner);
        market.ratchetDebtCeiling(id, 1_000e6);
        assertEq(market.hardCeilingOf(id), 1_000e6, "the lower ceiling must land");

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(MarketErrors.Market__CeilingNotDecreasing.selector, id, 1_000e6, 1_000e6)
        );
        market.ratchetDebtCeiling(id, 1_000e6);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(MarketErrors.Market__CeilingNotDecreasing.selector, id, 1_000e6, 2_000e6)
        );
        market.ratchetDebtCeiling(id, 2_000e6);
    }

    function test_debtCeilingIsOwnerOnlyAndRequiresAnExistingMarket() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        market.ratchetDebtCeiling(id, 1);

        Id ghostId = market.idOf(_uncreatedParams());
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(MarketErrors.Market__NotCreated.selector, ghostId));
        market.ratchetDebtCeiling(ghostId, 1);
    }

    // --------------------------------------------------------------------------------
    // External accrueInterest
    // --------------------------------------------------------------------------------

    /// @dev Permissionless and idempotent within a block. It exists so that anyone can bring a
    ///      market's clock forward without taking a position in it, and nothing in the suite
    ///      had ever called it directly.
    function test_accrueInterestIsPermissionlessAndIdempotentWithinABlock() public {
        _supply(100_000 * 10 ** LOAN_DECIMALS);
        _postCollateral(borrower, 1_000e18);
        _borrow(borrower, 10_000 * 10 ** LOAN_DECIMALS);

        uint256 borrowBefore = market.marketOf(id).totalBorrowAssets;

        vm.warp(block.timestamp + 1 days);

        vm.prank(attacker);
        market.accrueInterest(params);
        uint256 afterFirst = market.marketOf(id).totalBorrowAssets;
        assertGt(afterFirst, borrowBefore, "a day of interest must land");

        // Second call in the same block: `elapsed == 0` returns early, so nothing moves.
        vm.prank(attacker);
        market.accrueInterest(params);
        assertEq(market.marketOf(id).totalBorrowAssets, afterFirst, "a second call in the same block is a no-op");
    }

    /// @dev With no debt outstanding the accrual body is skipped entirely and only the clock
    ///      advances. Worth pinning: a rate applied to a zero principal is zero, but the
    ///      `lastUpdate` write still has to happen or the next accrual double-counts.
    function test_accrueInterestWithNoDebtOnlyMovesTheClock() public {
        _supply(1_000 * 10 ** LOAN_DECIMALS);
        uint256 supplyBefore = market.marketOf(id).totalSupplyAssets;

        vm.warp(block.timestamp + 1 days);
        market.accrueInterest(params);

        assertEq(market.marketOf(id).totalSupplyAssets, supplyBefore, "no debt means no interest");
        assertEq(market.marketOf(id).lastUpdate, block.timestamp, "the clock must still advance");
    }

    // --------------------------------------------------------------------------------
    // Construction
    // --------------------------------------------------------------------------------

    /// @dev The three risk parameters baked in at deployment and never changeable afterwards.
    ///      A zero depth multiplier would make the depth ceiling zero and no market could ever
    ///      borrow; above 10 000 bps it would claim liquidators can unwind more than the whole
    ///      order book; a zero absolute ceiling disables A1.1 entirely.
    function test_constructorRejectsMalformedRiskParameters() public {
        vm.expectRevert(MarketErrors.Market__InvalidParameter.selector);
        new CotejoMarket(owner, 0, MAX_ADAPTER_DEBT_USD);

        vm.expectRevert(MarketErrors.Market__InvalidParameter.selector);
        new CotejoMarket(owner, 10_001, MAX_ADAPTER_DEBT_USD);

        vm.expectRevert(MarketErrors.Market__InvalidParameter.selector);
        new CotejoMarket(owner, DEPTH_MULTIPLIER_BPS, 0);
    }

    // --------------------------------------------------------------------------------
    // Liquidity and solvency boundaries
    // --------------------------------------------------------------------------------

    /// @dev Suppliers share one pool with borrowers, so a withdrawal that would leave less on
    ///      hand than is currently lent out has to fail. Without this the last supplier out
    ///      would take assets that are already someone else's debt.
    function test_withdrawCannotDrainLiquidityThatIsLentOut() public {
        _supply(100_000 * 10 ** LOAN_DECIMALS);
        _postCollateral(borrower, 10_000e18);
        _borrow(borrower, 50_000 * 10 ** LOAN_DECIMALS);

        vm.prank(supplier);
        vm.expectPartialRevert(MarketErrors.Market__InsufficientLiquidity.selector);
        market.withdraw(params, 60_000 * 10 ** LOAN_DECIMALS, 0, supplier, supplier);
    }

    /// @dev The mirror image on the borrow side: a borrower cannot take out more than the pool
    ///      holds, however well collateralised they are. Collateral here is worth ~$10M
    ///      against a $1 000 pool, so solvency passes and liquidity is what binds — which is
    ///      the ordering the error has to get right for the caller to understand it.
    function test_borrowCannotExceedTheSuppliedLiquidity() public {
        _supply(1_000 * 10 ** LOAN_DECIMALS);
        _postCollateral(borrower, 100_000e18);

        vm.prank(borrower);
        vm.expectPartialRevert(MarketErrors.Market__InsufficientLiquidity.selector);
        market.borrow(params, 5_000 * 10 ** LOAN_DECIMALS, 0, borrower, borrower);
    }

    /// @dev Withdrawing collateral is the other action that increases exposure, and it is
    ///      checked against the same LLTV as borrowing. Half the collateral leaves the
    ///      position needing $80k of borrowing power against $50k of collateral.
    function test_withdrawCollateralCannotLeaveThePositionUnhealthy() public {
        _supply(200_000 * 10 ** LOAN_DECIMALS);
        _postCollateral(borrower, 1_000e18); // $100k at $100
        _borrow(borrower, 80_000 * 10 ** LOAN_DECIMALS); // under the 86% ceiling

        vm.prank(borrower);
        vm.expectPartialRevert(MarketErrors.Market__InsufficientCollateral.selector);
        market.withdrawCollateral(params, 500e18, borrower, borrower);
    }

    /// @notice A liquidator cannot be paid collateral the borrower does not have.
    ///
    /// @dev This is the A4 path. Once debt exceeds collateral value the close factor opens to
    ///      100%, so the arithmetic asks for more collateral than exists. The truncation is
    ///      what stops the subtraction underflowing, and what leaves the remainder to be
    ///      recognised as bad debt rather than silently taken from the next borrower.
    function test_liquidationSeizureIsTruncatedToTheCollateralActuallyHeld() public {
        _supply(200_000 * 10 ** LOAN_DECIMALS);
        _postCollateral(borrower, 1_000e18); // $100k
        _borrow(borrower, 85_000 * 10 ** LOAN_DECIMALS);

        // Collateral halves. Debt $85k against collateral worth $50k: insolvent, not merely
        // unhealthy. Every source agrees, so the oracle is perfectly healthy while it happens.
        _allAgreeOnCollateral(COL_PRICE_USD / 2);

        uint256 debtShares = market.positionOf(id, borrower).borrowShares;

        vm.prank(liquidator);
        (uint256 seized,) = market.liquidate(params, borrower, 0, debtShares);

        assertEq(seized, 1_000e18, "seizure must stop at the collateral actually held");
        assertEq(market.positionOf(id, borrower).collateral, 0, "the position is emptied, not overdrawn");
    }

    // --------------------------------------------------------------------------------
    // Degraded-mode guards
    // --------------------------------------------------------------------------------

    function test_degradedWindDownRefusesZeroShares() public {
        vm.prank(liquidator);
        vm.expectRevert(MarketErrors.Market__ZeroShares.selector);
        market.liquidateDegraded(params, borrower, 0);
    }

    /// @notice An adapter that has never produced a usable price cannot be wound down against.
    ///
    /// @dev The realistic shape of this is a market created against an oracle that breaks
    ///      before it ever serves: `_degradedSince` is set by the first failed read, but no
    ///      anchor was ever written. A2 decides *who* may be wound down from the anchor, so
    ///      with no anchor there is no eligibility test to run — and defaulting it would make
    ///      every position liquidable at a price nobody ever published.
    function test_degradedWindDownRefusesWithoutAPriceAnchor() public {
        _supply(100_000 * 10 ** LOAN_DECIMALS);
        _postCollateral(borrower, 1_000e18);

        // Break it before any successful observation ever anchors a price.
        _degradeOracle();
        market.pokeOracleState(params);
        vm.warp(block.timestamp + 73 hours);

        vm.prank(liquidator);
        vm.expectRevert(
            abi.encodeWithSelector(MarketErrors.Market__NoPriceAnchor.selector, address(adapter))
        );
        market.liquidateDegraded(params, borrower, 1);
    }

    /// @notice Degradation is a state the market leaves on its own when the oracle comes back.
    ///
    /// @dev Worth pinning precisely because the wind-down it gates is destructive. If
    ///      `_degradedSince` were sticky, a single transient disagreement would leave the
    ///      market permanently 72 hours away from price-free liquidation. `OracleRecovered`
    ///      had never been emitted in any test.
    function test_oracleRecoveryClearsDegradedStateOnItsOwn() public {
        _degradeOracle();

        vm.expectEmit(true, false, false, false);
        emit ICotejoMarket.OracleDegraded(address(adapter), block.timestamp);
        market.pokeOracleState(params);

        (bool healthyWhileBroken,) = market.isOracleHealthy(params);
        assertFalse(healthyWhileBroken, "a disagreeing source must degrade the market");

        // The rogue source falls back into line. Nothing is done to the market itself.
        _refresh(HEARTBEAT);

        vm.expectEmit(true, false, false, false);
        emit ICotejoMarket.OracleRecovered(address(adapter));
        market.pokeOracleState(params);

        (bool healthyAfter,) = market.isOracleHealthy(params);
        assertTrue(healthyAfter, "recovery must be automatic, not administrative");
    }

    /// @dev The public solvency view answers `false` when it cannot tell, rather than throwing
    ///      or guessing. An integrator polling this during an outage must read "do not treat
    ///      this as safe", which is the same fail-closed direction the rest of the system takes.
    function test_isHealthyReportsFalseWhenNoPriceIsAvailable() public {
        _supply(100_000 * 10 ** LOAN_DECIMALS);
        _postCollateral(borrower, 1_000e18);
        _borrow(borrower, 10_000 * 10 ** LOAN_DECIMALS);
        assertTrue(market.isHealthy(params, borrower), "well-collateralised while the oracle works");

        _degradeOracle();
        assertFalse(market.isHealthy(params, borrower), "unknown must read as unhealthy, not as healthy");
    }

    // --------------------------------------------------------------------------------
    // R5 against route tolerance
    // --------------------------------------------------------------------------------

    /// @notice A route tolerant enough to swallow a 100% error admits no safe incentive at all.
    ///
    /// @dev R5 derives the incentive ceiling from `1 - deviationCombined`. That subtraction
    ///      says something the threat model states and no test had shown: route tolerance has
    ///      an upper bound implied by the market, not only by the oracle. At 50% tolerance on
    ///      each of the two routes the combined error reaches 100%, the ceiling collapses, and
    ///      the market is refused outright rather than created with an incentive that cannot
    ///      be honoured.
    function test_createMarketRefusesWhenRouteToleranceLeavesNoSafeIncentive() public {
        _recommitBothRoutesAt(5_000); // 50% + 50% = 100%

        // The adapter freezes route policy at construction (R8), so it has to be built after
        // the loosened routes are live.
        CotejoOracleAdapter loose =
            new CotejoOracleAdapter(address(router), COL_ASSET, LOAN_ASSET, COL_DECIMALS, LOAN_DECIMALS);

        MarketParams memory p = params;
        p.oracleAdapter = address(loose);

        vm.expectRevert(
            abi.encodeWithSelector(MarketErrors.Market__R5_NoViableIncentive.selector, 1e18, LLTV)
        );
        market.createMarket(p, LIF);
    }

    // --------------------------------------------------------------------------------
    // Accounting bounds
    // --------------------------------------------------------------------------------

    /// @dev Balances are packed into `uint128`. The guard turns what would be a silent
    ///      truncation into a typed revert, and it fires before any token moves.
    function test_amountsThatDoNotFitInUint128AreRefused() public {
        uint256 tooBig = uint256(type(uint128).max) + 1;
        loan.mint(supplier, tooBig);

        vm.prank(supplier);
        vm.expectPartialRevert(MarketErrors.Market__MaxUint128Overflow.selector);
        market.supply(params, tooBig, 0, supplier);
    }

    // --------------------------------------------------------------------------------
    // Local helpers
    // --------------------------------------------------------------------------------

    /// @dev Every source agrees on a new collateral price. The router stays healthy — this is
    ///      a real move, not a disagreement.
    function _allAgreeOnCollateral(uint256 colPrice) internal {
        vm.warp(block.timestamp + HEARTBEAT);
        for (uint256 i; i < SOURCE_COUNT; ++i) {
            _attest(i, COL_ASSET, colPrice, BASE_DEPTH_USD, block.timestamp);
            _attest(i, LOAN_ASSET, LOAN_PRICE_USD, BASE_DEPTH_USD, block.timestamp);
        }
    }

    /// @dev One source reports 100x while the rest stay honest, so the route trips INV-2 and
    ///      the router refuses. The market sees a refusal, not a price.
    function _degradeOracle() internal {
        vm.warp(block.timestamp + HEARTBEAT);
        for (uint256 i = 1; i < SOURCE_COUNT; ++i) {
            _attest(i, COL_ASSET, COL_PRICE_USD, BASE_DEPTH_USD, block.timestamp);
            _attest(i, LOAN_ASSET, LOAN_PRICE_USD, BASE_DEPTH_USD, block.timestamp);
        }
        _attest(0, COL_ASSET, COL_PRICE_USD * 100, BASE_DEPTH_USD, block.timestamp);
        _attest(0, LOAN_ASSET, LOAN_PRICE_USD, BASE_DEPTH_USD, block.timestamp);
    }

    /// @dev Replaces both live routes with a given deviation tolerance, waiting out the
    ///      governor's timelock and re-publishing prices afterwards so nothing is stale.
    function _recommitBothRoutesAt(uint16 deviationBps) internal {
        address[] memory routeSources = new address[](SOURCE_COUNT);
        for (uint256 i; i < SOURCE_COUNT; ++i) routeSources[i] = address(sources[i]);

        IPriceRouter.Route memory r = IPriceRouter.Route({
            sources: routeSources,
            minSources: 3,
            maxDeviationBps: deviationBps,
            maxStalenessSeconds: STALENESS,
            reporterHeartbeatSeconds: HEARTBEAT,
            maxSourcesPerOperatorGroup: 1
        });

        vm.startPrank(owner);
        governor.proposeRoute(COL_ASSET, r);
        governor.proposeRoute(LOAN_ASSET, r);
        vm.stopPrank();

        vm.warp(block.timestamp + governor.ROUTE_TIMELOCK());
        governor.executeRoute(COL_ASSET);
        governor.executeRoute(LOAN_ASSET);

        _seedPrices(COL_PRICE_USD, LOAN_PRICE_USD, BASE_DEPTH_USD);
    }

    // --------------------------------------------------------------------------------
    // The interest rate model's own bounds
    // --------------------------------------------------------------------------------

    function test_irmConstructorRejectsAZeroMarket() public {
        vm.expectRevert(MarketErrors.Market__InvalidParameter.selector);
        new AdaptiveCurveIrm(address(0));
    }

    /// @notice Utilization above 100% is treated as exactly 100%, not extrapolated.
    ///
    /// @dev `borrowRateView` is unguarded by design — it is a quote, it writes nothing — which
    ///      means anyone can hand it a `Market` struct the real market would never produce.
    ///      The clamp is what stops that from being interesting: the curve is only defined up
    ///      to full utilization, and without the clamp an over-100% struct would push `err`
    ///      past `+WAD` and quote a rate off the end of the curve.
    ///
    ///      The assertion is a comparison rather than a number, so it stays true if the curve
    ///      is ever retuned: 200% utilization must quote exactly what 100% quotes.
    function test_utilizationAboveFullIsClampedRatherThanExtrapolated() public view {
        Market memory full = _syntheticMarket(1_000e6, 1_000e6, 1 hours);
        Market memory impossible = _syntheticMarket(1_000e6, 2_000e6, 1 hours);

        assertEq(
            irm.borrowRateView(params, impossible),
            irm.borrowRateView(params, full),
            "beyond full utilization the curve must flatten, not continue"
        );
    }

    /// @notice The rate anchor stops falling at its floor however long a market sits idle.
    ///
    /// @dev The anchor slides towards zero while utilization is under target. Without a floor
    ///      a market left alone long enough would quote an effectively zero borrow rate, and
    ///      the first borrower back would get free leverage until the curve climbed again.
    ///
    ///      Stated as two idle periods an order of magnitude apart quoting the same rate: if
    ///      the floor did not bind, ten times the drift would not produce the same answer.
    function test_theRateAnchorStopsFallingAtItsFloor() public view {
        Market memory idleOneMonth = _syntheticMarket(1_000e6, 0, 30 days);
        Market memory idleTenMonths = _syntheticMarket(1_000e6, 0, 300 days);
        Market memory idleOneHour = _syntheticMarket(1_000e6, 0, 1 hours);

        uint256 month = irm.borrowRateView(params, idleOneMonth);
        uint256 tenMonths = irm.borrowRateView(params, idleTenMonths);
        uint256 hour = irm.borrowRateView(params, idleOneHour);

        assertGt(month, 0, "the floor is a floor, not zero");
        assertEq(tenMonths, month, "ten times the drift must not go ten times lower");
        assertGt(hour, month, "and the floor must not bind after an hour, or it is not a floor");
    }

    /// @dev A `Market` struct as the model sees it. `lastUpdate` is expressed as an age so the
    ///      elapsed time the curve integrates over is the thing under test.
    function _syntheticMarket(uint128 supplyAssets, uint128 borrowAssets, uint256 age)
        internal
        view
        returns (Market memory m)
    {
        m.totalSupplyAssets = supplyAssets;
        m.totalSupplyShares = supplyAssets;
        m.totalBorrowAssets = borrowAssets;
        m.totalBorrowShares = borrowAssets;
        m.lastUpdate = uint128(block.timestamp - age);
        m.liquidationIncentiveFactor = uint128(LIF);
    }

    // --------------------------------------------------------------------------------
    // Fixed-point truncation
    // --------------------------------------------------------------------------------

    /// @notice A price published at a scale that cannot survive the trip to 18 decimals is
    ///         refused by the router, before anything downstream can round it away.
    ///
    /// @dev `PriceRouter` normalises every source to `ROUTER_DECIMALS = 18` and
    ///      `AggregationLib.normalize` reverts rather than returning zero when a downscale
    ///      would annihilate the value. That ordering matters more than it looks: it means the
    ///      adapter never has to defend against a zero denominator coming out of the router,
    ///      and the refusal carries the scale that caused it instead of a bare zero.
    ///
    ///      The reporters here are wrong about scale, not about value. Every source agrees
    ///      with every other, the route is healthy by every invariant it has, and the number
    ///      is still refused — which is the behaviour, not a failure of it.
    function test_priceAtAnUnrepresentableScaleIsRefusedByTheRouter() public {
        // 1 unit at 24 decimals is 1e-24 USD: zero once rescaled to 18.
        _allAttestLoanAt(1, 24);

        vm.expectRevert(
            abi.encodeWithSelector(CotejoErrors.Cotejo__PrecisionLoss.selector, uint256(1), uint8(24), uint8(18))
        );
        adapter.price();

        // The market has to read that as "no price", not as a price of zero.
        (bool healthy,) = market.isOracleHealthy(params);
        assertFalse(healthy, "an unusable price must degrade the market");

        vm.prank(borrower);
        vm.expectPartialRevert(MarketErrors.Market__OracleDegraded.selector);
        market.borrow(params, 1, 0, borrower, borrower);
    }

    /// @notice A collateral/loan ratio too small to represent reads as no price, never as zero.
    ///
    /// @dev The other end of the same arithmetic. Here both prices convert to WAD cleanly and
    ///      it is the ratio between them that lands under one unit of `PRICE_SCALE` after the
    ///      decimal adjustment, so `price()` returns a clean zero rather than reverting.
    ///
    ///      Treating that zero as a price would value every borrower's collateral at nothing
    ///      and make the whole market liquidatable at a price no reporter ever published.
    ///      `_tryPrice` turns it into a refusal instead, which routes into degraded mode — and
    ///      degraded mode blocks `liquidate` outright.
    function test_aRatioTooSmallToRepresentReadsAsNoPriceRatherThanZero() public {
        _postCollateral(borrower, 1_000e18);

        // Collateral at 1e-18 USD against a loan token at $1e7. The gap is absurd on purpose:
        // the point is the truncation, not the scenario.
        _allAttestBoth(1, 18, 1e25, 18);

        assertEq(adapter.price(), 0, "the ratio truncates to zero without reverting");

        (bool healthy, bytes memory err) = market.isOracleHealthy(params);
        assertFalse(healthy, "a zero price must read as no price");
        assertEq(err.length, 0, "there is no oracle error to report: the read succeeded and was unusable");

        // And the destructive path stays shut while that is true.
        vm.prank(liquidator);
        vm.expectPartialRevert(MarketErrors.Market__OracleDegraded.selector);
        market.liquidate(params, borrower, 0, 1);
    }

    /// @dev Publishes one loan price, at a chosen scale, from every source.
    function _allAttestLoanAt(uint256 price, uint8 decimals_) internal {
        vm.warp(block.timestamp + HEARTBEAT);
        for (uint256 i; i < SOURCE_COUNT; ++i) {
            _attestScaled(i, COL_ASSET, COL_PRICE_USD, 18);
            _attestScaled(i, LOAN_ASSET, price, decimals_);
        }
    }

    function _allAttestBoth(uint256 colPrice, uint8 colDec, uint256 loanPrice, uint8 loanDec) internal {
        vm.warp(block.timestamp + HEARTBEAT);
        for (uint256 i; i < SOURCE_COUNT; ++i) {
            _attestScaled(i, COL_ASSET, colPrice, colDec);
            _attestScaled(i, LOAN_ASSET, loanPrice, loanDec);
        }
    }

    /// @dev `MarketTestBase._attest` fixes the scale at 18. These cases are about the scale, so
    ///      they need their own signer path.
    function _attestScaled(uint256 i, bytes32 asset, uint256 price, uint8 decimals_) internal {
        AttestationSource.PriceAttestation memory att = AttestationSource.PriceAttestation({
            asset: asset,
            price: price,
            decimals: decimals_,
            observedAt: block.timestamp,
            depthUsd: BASE_DEPTH_USD,
            sourceId: sources[i].SOURCE_ID()
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(reporterKeys[i], sources[i].hashAttestation(att));
        sources[i].submit(att, abi.encodePacked(r, s, v));
    }
}
