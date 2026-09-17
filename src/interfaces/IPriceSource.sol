// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title IPriceSource
/// @notice Adapter interface every Cotejo price source implements.
/// @dev Three rules bind every implementation:
///
///      1. `latestPrice` is `view` (D3). The whole read path — source, router, adapter —
///         must stay `view` so that `AggregatorV3Interface.latestRoundData()` is `view`,
///         which is how every existing consumer calls it. A source that needs to write
///         storage to answer is not a source. A pull-based source (RedStone-style, where
///         the payload rides in calldata) can still extract from `msg.data` in a `view`
///         context; that is the documented path for such a source.
///
///      2. Fail-closed. Never return zero, never return a default, never return the last
///         known good value past its usable life. Revert with a typed error instead.
///
///      3. `operatorGroup` is read on every call, never cached by the router. A source's
///         operator can change after a route is committed, and INV-5 must catch that at
///         read time, not only at proposal time.
interface IPriceSource {
    /// @notice The most recent price this source can attest to for `asset`.
    /// @dev MUST revert when the asset is unsupported, when no observation exists, or when
    ///      the observation is not fit to serve. MUST NOT return zero.
    ///      Staleness is judged by the router against the route's own window, so a source
    ///      reports `observedAt` honestly and does not apply a staleness policy of its own.
    /// @param asset Identifier of the asset, e.g. `keccak256("WBT/USD")`.
    /// @return price Price expressed in `decimals`. Always strictly greater than zero.
    /// @return decimals Number of decimals `price` is scaled by.
    /// @return observedAt Unix timestamp of observation at the origin venue, not the
    ///         timestamp of the on-chain write. These differ, and the difference is the
    ///         latency the router is actually trying to bound.
    /// @return group Operator group this source currently belongs to, for INV-5.
    function latestPrice(bytes32 asset)
        external
        view
        returns (uint256 price, uint8 decimals, uint256 observedAt, bytes32 group);

    /// @notice Operator group for `asset` without requiring a live price.
    /// @dev Route proposal happens before any attestation exists, so `latestPrice` would
    ///      revert and INV-5 could not be validated up front. This is the read that makes
    ///      proposal-time enforcement possible.
    /// @param asset Identifier of the asset.
    /// @return group Operator group, or `bytes32(0)` when the source does not serve the asset.
    function operatorGroupOf(bytes32 asset) external view returns (bytes32 group);

    /// @notice Whether this source is configured to serve `asset`.
    /// @dev Says nothing about whether a fresh price exists right now.
    /// @param asset Identifier of the asset.
    /// @return supported True when the source can serve the asset.
    function supportsAsset(bytes32 asset) external view returns (bool supported);

    /// @notice Market depth behind the latest observation for `asset`, in whole USD.
    /// @dev MUST revert under exactly the conditions `latestPrice` reverts, so a consumer
    ///      cannot obtain a depth from a source the router would refuse to price from.
    ///
    ///      A source with no depth concept returns zero rather than reverting. Zero is not a
    ///      neutral value here: it drives the consuming market's debt ceiling to zero, which
    ///      makes such a source unusable under a market by construction rather than by a
    ///      comment asking nobody to try.
    /// @param asset Identifier of the asset.
    /// @return depthUsd Depth in whole USD, or zero when the source does not report one.
    function latestDepthUsd(bytes32 asset) external view returns (uint256 depthUsd);
}
