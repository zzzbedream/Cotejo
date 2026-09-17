// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Id} from "../types/MarketTypes.sol";

/// @title MarketErrors
/// @notice Every typed error the lending market can revert with.
library MarketErrors {
    // --- Admission rules, checked at creation ---

    /// @notice R1. A route backing this market has fewer than MIN_SOURCES required sources.
    error Market__R1_InsufficientRouteQuorum(bytes32 asset, uint256 minSources, uint256 required);

    /// @notice R2. A route backing this market spans fewer than 3 distinct operator groups.
    error Market__R2_ConcentratedOracle(bytes32 asset, uint256 distinctGroups, uint256 required);

    /// @notice R3. lltv exceeds MAX_LLTV.
    error Market__R3_LltvTooHigh(uint256 lltv, uint256 maxLltv);

    /// @notice R4. The interest rate model is not whitelisted.
    error Market__R4_IrmNotWhitelisted(address irm);

    /// @notice R5. The liquidation incentive exceeds what the route tolerance allows.
    error Market__R5_IncentiveTooHigh(uint256 requested, uint256 derivedMax);

    /// @notice R5. Route tolerance is so wide that no viable liquidation incentive exists.
    /// @dev Occurs when deviationCombined >= WAD - lltv: the liquidator would receive less
    ///      than they repay, so nobody would ever liquidate.
    error Market__R5_NoViableIncentive(uint256 deviationCombined, uint256 lltv);

    /// @notice R6. The adapter's asset identifier does not resolve to the market's token.
    error Market__R6_AssetTokenMismatch(bytes32 asset, address registered, address expected);

    /// @notice R7. A route lacks the redundancy a market requires.
    error Market__R7_InsufficientRedundancy(bytes32 asset, uint256 sources, uint256 required);

    /// @notice R8. The live route is weaker than the snapshot the adapter was built against.
    error Market__R8_RoutePolicyWeakened(bytes32 asset);

    // --- Market lifecycle ---

    error Market__AlreadyCreated(Id id);
    error Market__NotCreated(Id id);
    error Market__InvalidParameter();
    error Market__InconsistentInput();

    // --- Degraded mode (§3 of the threat model) ---

    /// @notice The oracle is not answering, so this operation is blocked.
    /// @dev Carries the router's own revert data so a caller can see which invariant fired.
    error Market__OracleDegraded(Id id, bytes oracleError);

    /// @notice Collateral cannot be withdrawn while the position carries debt and the oracle
    ///         is degraded, because solvency cannot be checked.
    error Market__CollateralLockedWhileDegraded(Id id);

    // --- Solvency and liquidity ---

    error Market__InsufficientCollateral(Id id, address borrower);
    error Market__InsufficientLiquidity(Id id, uint256 requested, uint256 available);

    /// @notice The borrow would push the adapter's markets past their shared depth cap (M1).
    /// @dev `wouldBe` is the total across every market sharing the adapter, not this market
    ///      alone: the order book behind the cap does not care how many `Id`s were minted
    ///      against it.
    error Market__DepthCapExceeded(Id id, uint256 wouldBe, uint256 cap);

    /// @notice The borrow would push this market past its governance ratchet (A1.1).
    error Market__DebtCeilingExceeded(Id id, uint256 wouldBe, uint256 ceiling);

    /// @notice A debt ceiling may only ever be lowered.
    error Market__CeilingNotDecreasing(Id id, uint256 current, uint256 requested);

    /// @notice One adapter may not back more markets than the aggregate loop can afford.
    error Market__TooManyMarketsPerAdapter(address adapter, uint256 count);

    /// @notice The depth cap cannot be computed because a depth reading is unavailable.
    error Market__DepthUnavailable(Id id);

    /// @notice A proposed interest rate model has not finished its wait.
    error Market__IrmTimelockNotElapsed(address irm, uint256 eta, uint256 nowTs);

    // --- Price band (A3) ---

    /// @notice The live price has climbed faster than the band permits.
    /// @dev Raised only on `borrow` and `withdrawCollateral`, and only upward. Liquidation is
    ///      never gated by the band: a breaker on the downward side would freeze liquidations
    ///      during a real crash and manufacture the bad debt it claims to prevent.
    error Market__PriceBandExceeded(address adapter, uint256 observed, uint256 ceiling);

    // --- Degraded wind-down (A2) ---

    /// @notice The oracle has not been degraded long enough to open the wind-down path.
    error Market__NotDegradedLongEnough(address adapter, uint256 since, uint256 required);

    /// @notice No price anchor exists, so eligibility cannot be established.
    error Market__NoPriceAnchor(address adapter);

    /// @notice The position is solvent at the anchor, so it may not be wound down.
    error Market__HealthyAtAnchor(Id id, address borrower);

    // --- Liquidation ---

    error Market__HealthyPosition(Id id, address borrower);
    error Market__CloseFactorExceeded(uint256 repaid, uint256 maxRepayable);

    // --- Token handling (M6) ---

    /// @notice The balance delta did not match the amount expected.
    /// @dev Fee-on-transfer and rebasing tokens fail here on first use rather than corrupting
    ///      the accounting silently.
    error Market__UnexpectedBalanceDelta(address token, uint256 expected, uint256 actual);

    // --- Math ---

    error Market__ZeroAssets();
    error Market__ZeroShares();
    error Market__MaxUint128Overflow(uint256 value);
}
