// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title ICotejoOracleAdapter
/// @notice Translates two Cotejo routes into the single collateral/loan price a market needs,
///         and exposes enough of the routes for the market to verify R1, R2, R6, R7 and R8.
///
/// @dev **Two routes, not one.** Cotejo prices assets in USD; a market needs collateral priced
///      in loan token. So the adapter reads `collateralAsset/USD` and `loanAsset/USD` and
///      divides. Both routes must satisfy every admission rule, and a revert from either one
///      puts the market into degraded mode. Treating the loan token as a fixed USD numeraire
///      would be simpler and would blind the market to a depeg, which is exactly the kind of
///      unverifiable assumption this design refuses to make.
interface ICotejoOracleAdapter {
    /// @notice Price of one whole collateral token, expressed in loan tokens, scaled by
    ///         `PRICE_SCALE`.
    /// @dev Reverts, propagating Cotejo's typed error, whenever either route refuses to
    ///      answer. That revert *is* degraded mode — the market never sees a fabricated price.
    ///      Also reverts under R8 if either live route has been weakened since deployment.
    function price() external view returns (uint256);

    /// @notice Scale `price()` is expressed in.
    function PRICE_SCALE() external view returns (uint256);

    /// @notice The binding depth behind this market, in whole USD.
    /// @dev `min(minDepth(collateralRoute), minDepth(loanRoute))`, where `minDepth` is the
    ///      *smallest* `depthUsd` among a route's fresh sources (M1). A safety limit takes the
    ///      most conservative input available: one honest reporter is enough to cap it.
    ///      Reverts when either route refuses to answer.
    function bindingDepthUsd() external view returns (uint256);

    /// @notice USD price of one whole loan token, in WAD.
    /// @dev The depth cap is denominated in USD and the market's debt in loan tokens, so the
    ///      conversion needs this. If it cannot be produced the cap cannot be computed, and a
    ///      cap that cannot be computed blocks new borrowing rather than defaulting to
    ///      unlimited.
    function loanPriceUsd() external view returns (uint256);

    /// @notice Combined route tolerance, in WAD: `devCollateralRoute + devLoanRoute`.
    /// @dev Feeds the R5 liquidation-incentive bound.
    function deviationCombined() external view returns (uint256);

    // --- Introspection used by the market at creation time ---

    function router() external view returns (address);
    function collateralAsset() external view returns (bytes32);
    function loanAsset() external view returns (bytes32);
    function collateralTokenDecimals() external view returns (uint8);
    function loanTokenDecimals() external view returns (uint8);

    /// @notice The route policy frozen at deployment (R8).
    /// @param asset Either `collateralAsset()` or `loanAsset()`.
    /// @return minSources Quorum at the time the adapter was deployed.
    /// @return maxDeviationBps Tolerance at that time.
    /// @return distinctGroups Number of distinct operator groups at that time.
    function policySnapshot(bytes32 asset)
        external
        view
        returns (uint8 minSources, uint16 maxDeviationBps, uint8 distinctGroups);
}
