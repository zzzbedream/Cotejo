// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Unique identifier of a market: `keccak256(abi.encode(MarketParams))`.
type Id is bytes32;

/// @notice The immutable definition of a market.
/// @dev Every field is baked into the `Id`, so none of them can be changed after creation.
///      There is deliberately no setter for `lltv` anywhere in this codebase: a market whose
///      loan-to-value can be raised under live positions is the problem this design exists to
///      avoid. Changing any parameter means creating a new market and migrating to it.
/// @param collateralToken ERC-20 posted as collateral.
/// @param loanToken ERC-20 borrowed and supplied.
/// @param oracleAdapter Adapter translating Cotejo routes into a collateral/loan price.
/// @param irm Interest rate model, which must be whitelisted (R4).
/// @param lltv Liquidation loan-to-value, in WAD. Capped by `MAX_LLTV` (R3).
struct MarketParams {
    address collateralToken;
    address loanToken;
    address oracleAdapter;
    address irm;
    uint256 lltv;
}

/// @notice Per-market accounting.
/// @param totalSupplyAssets Loan tokens supplied, including accrued interest.
/// @param totalSupplyShares Shares representing that supply.
/// @param totalBorrowAssets Loan tokens borrowed, including accrued interest.
/// @param totalBorrowShares Shares representing that debt.
/// @param lastUpdate Timestamp of the last interest accrual. Seconds, never block numbers (M7).
/// @param liquidationIncentiveFactor LIF in WAD, fixed at creation and bounded by R5.
struct Market {
    uint128 totalSupplyAssets;
    uint128 totalSupplyShares;
    uint128 totalBorrowAssets;
    uint128 totalBorrowShares;
    uint128 lastUpdate;
    uint128 liquidationIncentiveFactor;
}

/// @notice A single account's stake in one market.
/// @dev Collateral is tracked per market and never pooled across markets. A market can only
///      ever touch collateral recorded under its own `Id`.
/// @param supplyShares Shares of the market's supply side.
/// @param borrowShares Shares of the market's debt.
/// @param collateral Collateral tokens posted, in token units.
struct Position {
    uint256 supplyShares;
    uint128 borrowShares;
    uint128 collateral;
}

/// @notice Rate-limited recording of the adapter's own price output (A3).
/// @dev The one place a price is stored anywhere in Cotejo, and it is bound by a rule that is
///      checkable in a single grep:
///
///        **INV-7'** — a stored price may only ever *restrict* an action. No code path may
///        compute a token amount from it.
///
///      It gates who may be wound down during a prolonged outage, and it bounds how fast the
///      live price may climb before borrowing pauses. It never sizes a seizure, a repayment,
///      or a transfer.
/// @param price Last accepted price, already clamped to the band.
/// @param at When it was accepted.
struct PriceAnchor {
    uint128 price;
    uint64 at;
}

/// @notice Depth observation anchoring the growth clamp (M1).
/// @dev Updated only on state-changing paths, so the read path stays `view`.
/// @param depthUsd Last accepted depth, in whole USD.
/// @param timestamp When it was accepted.
struct DepthAnchor {
    uint128 depthUsd;
    uint128 timestamp;
}
