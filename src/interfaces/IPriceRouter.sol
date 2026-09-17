// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title IPriceRouter
/// @notice Entry point for aggregated prices, and the surface RouteGovernor drives.
interface IPriceRouter {
    /// @notice Everything that governs how one asset's price is produced.
    /// @dev The five scalars pack into a single storage slot (1+2+4+4+1 = 12 bytes).
    /// @param sources Price sources consulted for the asset. 1..MAX_SOURCES_PER_ROUTE (D4).
    /// @param minSources Fresh sources required before a price is produced (INV-1).
    /// @param maxDeviationBps Tolerated spread across the fresh set, measured against the
    ///        median (D1), in basis points (INV-2).
    /// @param maxStalenessSeconds Oldest observation the router accepts (INV-3).
    /// @param reporterHeartbeatSeconds Cadence reporters are expected to publish at. Used
    ///        only to sanity-check `maxStalenessSeconds` at configuration time (D2).
    /// @param maxSourcesPerOperatorGroup Sources allowed to share one operator group.
    ///        Defaults to 1 (INV-5).
    struct Route {
        address[] sources;
        uint8 minSources;
        uint16 maxDeviationBps;
        uint32 maxStalenessSeconds;
        uint32 reporterHeartbeatSeconds;
        uint8 maxSourcesPerOperatorGroup;
    }

    /// @notice A route was committed for an asset.
    event RouteCommitted(bytes32 indexed asset, address[] sources, uint8 minSources);

    /// @notice An asset was paused by a guardian (INV-6).
    event Paused(bytes32 indexed asset, address indexed guardian);

    /// @notice An asset was unpaused by the governor after the full timelock (INV-6).
    event Unpaused(bytes32 indexed asset);

    /// @notice Aggregated price for `asset`.
    /// @dev Fail-closed. Reverts with `Cotejo__InsufficientSources` (INV-1),
    ///      `Cotejo__DeviationExceeded` (INV-2), `Cotejo__StalePrice` (INV-3),
    ///      `Cotejo__OperatorConcentration` (INV-5) or `Cotejo__Paused` (INV-6).
    ///      Never returns zero and never returns a stale price.
    /// @param asset Identifier of the asset.
    /// @return price Median of the fresh set, normalised to `ROUTER_DECIMALS`.
    /// @return decimals Always `ROUTER_DECIMALS`.
    /// @return observedAt Oldest `observedAt` in the fresh set. Deliberately the most
    ///         conservative value, so a consumer applying its own staleness check measures
    ///         against the weakest link rather than the strongest.
    function latestPrice(bytes32 asset)
        external
        view
        returns (uint256 price, uint8 decimals, uint256 observedAt);

    /// @notice The two smallest depth readings over the same fresh set `latestPrice` uses.
    /// @dev Subject to every invariant the price path applies — pause, quorum, operator
    ///      independence, spread — so a consumer cannot derive a debt ceiling from a set this
    ///      router would refuse to price from.
    /// @param asset Identifier of the asset.
    /// @return lowestUsd Smallest depth in the fresh set, in whole USD.
    /// @return secondLowestUsd Second smallest, or zero when the set holds fewer than two.
    /// @return count Size of the fresh set.
    function latestDepth(bytes32 asset)
        external
        view
        returns (uint256 lowestUsd, uint256 secondLowestUsd, uint8 count);

    /// @notice The active route for `asset`.
    function getRoute(bytes32 asset) external view returns (Route memory route);

    /// @notice Whether `asset` is currently paused.
    function isPaused(bytes32 asset) external view returns (bool paused);

    /// @notice Address allowed to commit routes and lift pauses.
    function governor() external view returns (address);

    /// @notice Reverts unless `route` is a valid route for `asset`.
    /// @dev One definition of validity, shared by `commitRoute` and by the governor at
    ///      proposal time, so the two can never drift apart.
    function validateRoute(bytes32 asset, Route calldata route) external view;

    /// @notice Grants or revokes a guardian's ability to pause. Governor only.
    function setGuardian(address guardian, bool active) external;

    /// @notice The ERC-20 an asset identifier prices, or zero if unbound.
    function tokenForAsset(bytes32 asset) external view returns (address token);

    /// @notice Binds an asset identifier to its ERC-20. Append-only; governor only.
    function registerAssetToken(bytes32 asset, address token) external;

    /// @notice Install a route. Callable only by the governor, which enforces the timelock.
    /// @dev There is no function anywhere on this contract that writes a price (INV-7).
    function commitRoute(bytes32 asset, Route calldata route) external;

    /// @notice Lift a pause. Governor only, and only after the full timelock (INV-6).
    function unpause(bytes32 asset) external;

    /// @notice Pause an asset immediately. Guardian only (INV-6).
    function pause(bytes32 asset) external;
}
