// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Id, MarketParams, Market, Position} from "../types/MarketTypes.sol";

/// @title ICotejoMarket
/// @notice Isolated lending markets over the Cotejo oracle.
/// @dev One singleton holds every market, keyed by `Id`, but the markets share nothing:
///      collateral, supply, debt and bad debt are all recorded per `Id`. A compromised
///      collateral can only reach the markets that name it.
interface ICotejoMarket {
    event MarketCreated(Id indexed id, MarketParams params, uint256 liquidationIncentiveFactor);
    event Supply(Id indexed id, address indexed onBehalf, uint256 assets, uint256 shares);
    event Withdraw(Id indexed id, address indexed onBehalf, address receiver, uint256 assets, uint256 shares);
    event SupplyCollateral(Id indexed id, address indexed onBehalf, uint256 assets);
    event WithdrawCollateral(Id indexed id, address indexed onBehalf, address receiver, uint256 assets);
    event Borrow(Id indexed id, address indexed onBehalf, address receiver, uint256 assets, uint256 shares);
    event Repay(Id indexed id, address indexed onBehalf, uint256 assets, uint256 shares);
    event Liquidate(
        Id indexed id,
        address indexed liquidator,
        address indexed borrower,
        uint256 repaidAssets,
        uint256 repaidShares,
        uint256 seizedCollateral,
        uint256 badDebtAssets
    );
    event AccrueInterest(Id indexed id, uint256 borrowRate, uint256 interest);
    event IrmWhitelisted(address indexed irm, bool allowed);

    /// @notice An interest rate model was queued for the whitelist (A5.3).
    event IrmProposed(address indexed irm, uint64 eta);

    /// @dev Keyed by adapter: depth belongs to the oracle routes, not to any one market.
    event DepthAnchorUpdated(address indexed adapter, uint256 depthUsd);

    /// @notice The interest rate model reverted or ran out of its gas budget.
    /// @dev Interest accrues at zero for that interval. Loud on purpose — a market emitting
    ///      this is a market whose IRM needs replacing, which means migrating to a new market.
    event IrmCallFailed(Id indexed id, address indexed irm);

    /// @notice A market's debt ceiling was ratcheted down.
    event DebtCeilingRatcheted(Id indexed id, uint256 newCeiling);

    /// @notice An adapter stopped answering. Starts the clock on the wind-down path (A2).
    event OracleDegraded(address indexed adapter, uint256 since);

    /// @notice An adapter started answering again. The clock resets.
    event OracleRecovered(address indexed adapter);

    /// @notice A position was wound down during a prolonged outage, at a price-free ratio.
    event LiquidateDegraded(
        Id indexed id,
        address indexed liquidator,
        address indexed borrower,
        uint256 repaidAssets,
        uint256 repaidShares,
        uint256 seizedCollateral,
        uint256 premiumBps
    );

    /// @notice Creates a market. Validates R1 through R8 and reverts on the first failure.
    /// @param params Immutable market definition.
    /// @param liquidationIncentiveFactor LIF in WAD, bounded by R5.
    function createMarket(MarketParams calldata params, uint256 liquidationIncentiveFactor)
        external
        returns (Id id);

    // --- Supply side. Needs no price. ---

    function supply(MarketParams calldata params, uint256 assets, uint256 shares, address onBehalf)
        external
        returns (uint256 suppliedAssets, uint256 suppliedShares);

    function withdraw(
        MarketParams calldata params,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256 withdrawnAssets, uint256 withdrawnShares);

    // --- Borrow side ---

    function supplyCollateral(MarketParams calldata params, uint256 assets, address onBehalf) external;

    function withdrawCollateral(
        MarketParams calldata params,
        uint256 assets,
        address onBehalf,
        address receiver
    ) external;

    function borrow(
        MarketParams calldata params,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256 borrowedAssets, uint256 borrowedShares);

    function repay(MarketParams calldata params, uint256 assets, uint256 shares, address onBehalf)
        external
        returns (uint256 repaidAssets, uint256 repaidShares);

    /// @notice Liquidates an unhealthy position. Blocked whenever the oracle is degraded.
    /// @dev Exactly one of `seizedCollateral` and `repaidShares` must be non-zero.
    function liquidate(
        MarketParams calldata params,
        address borrower,
        uint256 seizedCollateral,
        uint256 repaidShares
    ) external returns (uint256 seized, uint256 repaid);

    function accrueInterest(MarketParams calldata params) external;

    /// @notice Winds down an unhealthy position during a prolonged oracle outage (A2).
    ///
    /// @dev Consults **no live price**. The liquidator repays a fraction of the debt and
    ///      receives the same fraction of the collateral, plus a premium that escalates with
    ///      how long the outage has lasted.
    ///
    ///      Why this is not a way back in for the attacker: there is no price in the seizure
    ///      formula, so there is nothing to manipulate. At zero premium the seizure is exactly
    ///      pro-rata, which leaves the position's collateralisation ratio unchanged — it is
    ///      arithmetically neutral. The entire edge is the premium: capped at 10%, reached
    ///      only after 72 hours plus a seven-day ramp of *continuous* failure, limited to half
    ///      the debt, and requiring real loan tokens fronted against a position that is by
    ///      definition already underwater.
    ///
    ///      Eligibility is decided by the rate-limited price anchor. That is the one place a
    ///      stored price enters the market, and it obeys INV-7': it decides *who* may be wound
    ///      down, never *how much* is seized.
    function liquidateDegraded(MarketParams calldata params, address borrower, uint256 repaidShares)
        external
        returns (uint256 seizedCollateral, uint256 repaidAssets);

    /// @notice Records oracle availability and advances the price anchor. Permissionless.
    function pokeOracleState(MarketParams calldata params) external;

    /// @notice The adapter's price anchor and degradation clock.
    function oracleAnchor(address adapter)
        external
        view
        returns (uint256 anchoredPrice, uint64 anchoredAt, uint64 degradedSince);

    /// @notice Advances an adapter's depth anchor without borrowing. Permissionless.
    /// @dev Exists so the growth clamp cannot decay: the anchor previously moved only inside
    ///      `borrow`, so a quiet period accumulated unbounded growth allowance.
    function pokeDepthAnchor(MarketParams calldata params) external;

    /// @notice Queues an interest rate model for the whitelist (A5.3). Owner only.
    function proposeIrm(address irm) external;

    /// @notice Whitelists a matured proposal. Permissionless.
    function executeIrm(address irm) external;

    /// @notice Removes a model from the whitelist, or cancels a queued proposal. Immediate.
    function revokeIrm(address irm) external;

    /// @notice Timestamp from which a queued model may be whitelisted, or zero if none.
    function pendingIrm(address irm) external view returns (uint64 eta);

    /// @notice Lowers one market's debt ceiling. Monotonically decreasing.
    /// @dev Needs no timelock because it can only restrict. The worst a compromised owner
    ///      achieves is ratcheting every market to zero, which blocks new borrowing and leaves
    ///      liquidation untouched — a liveness loss, not a safety one, the same asymmetry the
    ///      oracle layer already applies to guardian pause.
    function ratchetDebtCeiling(Id id, uint128 newCeiling) external;

    // --- Views ---

    function marketOf(Id id) external view returns (Market memory);
    function positionOf(Id id, address user) external view returns (Position memory);
    function paramsOf(Id id) external view returns (MarketParams memory);

    /// @notice Debt ceiling for the adapter, in loan-token units.
    /// @dev The ceiling applies to every market sharing the adapter combined, not to each one
    ///      separately. Reverts when depth or the loan price cannot be read: a cap that cannot
    ///      be computed blocks new borrowing and never defaults to unlimited.
    function maxTotalBorrow(MarketParams calldata params) external view returns (uint256);

    /// @notice Total debt across every market sharing `adapter`, in loan-token units.
    function adapterTotalBorrow(address adapter) external view returns (uint256);

    /// @notice The governance ratchet in force for one market, in loan-token units.
    function hardCeilingOf(Id id) external view returns (uint256);

    /// @notice Whether the oracle is currently answering for this market.
    /// @return healthy True when a price is available.
    /// @return oracleError The router's raw revert data when it is not.
    function isOracleHealthy(MarketParams calldata params)
        external
        view
        returns (bool healthy, bytes memory oracleError);

    /// @notice Whether a position is solvent at the current price.
    function isHealthy(MarketParams calldata params, address user) external view returns (bool);

    function isIrmWhitelisted(address irm) external view returns (bool);
}
