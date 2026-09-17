// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title CotejoErrors
/// @notice Every typed error Cotejo can revert with, in one place.
/// @dev Cotejo is fail-closed: when a read cannot be proven safe, it reverts with one of
///      these instead of returning a stale price, a zero, or a default. A consumer that
///      reverts is a consumer that is still alive.
library CotejoErrors {
    // --- Aggregation / read path (the seven invariants) ---

    /// @notice INV-1. Fewer fresh sources than the route requires.
    error Cotejo__InsufficientSources(bytes32 asset, uint256 fresh, uint256 required);

    /// @notice INV-2. Spread across the fresh set exceeds the route's tolerance.
    /// @dev Deviation is measured against the median (D1), not the min or the max.
    error Cotejo__DeviationExceeded(bytes32 asset, uint256 deviationBps, uint256 maxBps);

    /// @notice INV-3. A source in the set observed its price too long ago.
    error Cotejo__StalePrice(bytes32 asset, address source, uint256 observedAt, uint256 maxStalenessSeconds);

    /// @notice INV-5. Too many sources in the set share one operator group.
    error Cotejo__OperatorConcentration(bytes32 asset, bytes32 group, uint256 count, uint256 maxAllowed);

    /// @notice INV-6. The asset is paused. Only the governor can lift it, after the timelock.
    error Cotejo__Paused(bytes32 asset);

    // --- Source-level failures ---

    /// @notice A source was asked for an asset it does not serve.
    error Cotejo__AssetNotSupported(bytes32 asset);

    /// @notice A source holds no usable observation for the asset.
    error Cotejo__NoPrice(bytes32 asset);

    /// @notice A price of zero is never a valid answer.
    error Cotejo__ZeroPrice(bytes32 asset);

    /// @notice An attestation claims to have observed a price in the future.
    error Cotejo__FutureObservation(uint256 observedAt, uint256 nowTs);

    /// @notice This exact attestation, or an older one, has already been consumed.
    error Cotejo__ReplayedAttestation(bytes32 asset, bytes32 digest);

    /// @notice The recovered signer is not a registered reporter for this source.
    error Cotejo__UnknownReporter(address recovered);

    /// @notice The reporter is registered but not authorised for this asset.
    error Cotejo__ReporterNotAuthorised(address reporter, bytes32 asset);

    /// @notice The attestation carries less market depth than the source demands.
    error Cotejo__InsufficientDepth(uint256 depthUsd, uint256 minDepthUsd);

    /// @notice TwapSource is a deliberate skeleton in v1. See the contract NatSpec.
    error Cotejo__TwapDisabled();

    // --- Route configuration ---

    /// @notice The route names more sources than MAX_SOURCES_PER_ROUTE (D4).
    error Cotejo__TooManySources(uint256 given, uint256 maxAllowed);

    /// @notice A route needs at least one source and a non-zero minSources.
    error Cotejo__EmptyRoute();

    /// @notice minSources can never exceed the number of sources configured.
    error Cotejo__MinSourcesUnreachable(uint256 minSources, uint256 sourceCount);

    /// @notice D2. maxStalenessSeconds must leave at least two heartbeats of slack.
    error Cotejo__StalenessBelowHeartbeat(uint32 maxStalenessSeconds, uint32 heartbeatSeconds);

    /// @notice A route parameter was left at zero where zero has no safe meaning.
    error Cotejo__InvalidRouteParameter();

    /// @notice The same source address appears twice in one route.
    error Cotejo__DuplicateSource(address source);

    /// @notice A configured source does not serve the asset the route is for.
    error Cotejo__SourceDoesNotServeAsset(address source, bytes32 asset);

    /// @notice No route has been committed for this asset.
    error Cotejo__RouteNotConfigured(bytes32 asset);

    /// @notice An asset identifier is already bound to a token. The registry is append-only.
    /// @dev Remapping would let governance point an asset id at a different token, and every
    ///      market created under the old mapping would silently start valuing something it
    ///      does not hold. A mutable registry makes the check that depends on it decorative.
    error Cotejo__AssetAlreadyRegistered(bytes32 asset, address token);

    /// @notice The asset identifier has no token bound to it.
    error Cotejo__AssetNotRegistered(bytes32 asset);

    // --- Governance / timelock (INV-4, INV-6) ---

    /// @notice Caller is not the RouteGovernor.
    error Cotejo__OnlyGovernor(address caller);

    /// @notice Caller is not a registered guardian.
    error Cotejo__OnlyGuardian(address caller);

    /// @notice INV-4. The 48h timelock on this proposal has not elapsed.
    error Cotejo__TimelockNotElapsed(bytes32 proposalId, uint256 eta, uint256 nowTs);

    /// @notice The proposal does not exist, or was already executed or cancelled.
    error Cotejo__NoSuchProposal(bytes32 proposalId);

    /// @notice A proposal for this asset is already queued.
    error Cotejo__ProposalAlreadyQueued(bytes32 proposalId);

    /// @notice The asset is not paused, so there is nothing to lift.
    error Cotejo__NotPaused(bytes32 asset);

    // --- Adapter / AggregatorV3 compatibility ---

    /// @notice Cotejo computes prices on demand and keeps no round history.
    /// @dev Returning a fabricated historical round would violate fail-closed, so
    ///      getRoundData reverts rather than inventing one.
    error Cotejo__HistoricalDataUnavailable(uint80 requestedRoundId);

    /// @notice Rescaling to the consumer's decimals would round the price to zero.
    error Cotejo__PrecisionLoss(uint256 price, uint8 fromDecimals, uint8 toDecimals);

    /// @notice The price does not fit in the int256 that AggregatorV3Interface returns.
    error Cotejo__PriceOverflowsInt256(uint256 price);

    // --- Library preconditions ---

    /// @notice A statistic was requested over an empty set.
    error Cotejo__EmptySet();

    /// @notice Decimal normalisation was asked for an implausible exponent.
    error Cotejo__DecimalsOutOfRange(uint8 decimals);
}
