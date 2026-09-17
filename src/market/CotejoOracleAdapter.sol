// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ICotejoOracleAdapter} from "./interfaces/ICotejoOracleAdapter.sol";
import {MarketErrors} from "./libraries/MarketErrors.sol";
import {MathLib} from "./libraries/MathLib.sol";
import {IPriceRouter} from "../interfaces/IPriceRouter.sol";
import {IPriceSource} from "../interfaces/IPriceSource.sol";

/// @title CotejoOracleAdapter
/// @notice Turns two Cotejo routes into the single collateral/loan price a market needs.
///
/// @dev Immutable in every respect that matters. The routes it reads, the tokens it describes,
///      and the policy it demands of those routes are all fixed at deployment. Changing any of
///      them means a new adapter, and therefore a new market — which is the same rule the
///      market itself lives by.
///
///      **R8 — the routes cannot be weakened underneath it.** The constructor records each
///      route's quorum, tolerance, and operator spread. Every `price()` call re-reads the live
///      route and reverts if it has moved in the permissive direction on any of those three
///      axes. Governance can harden a route under a live market; it cannot loosen one. Without
///      this, every admission rule checked at creation would be advisory: governance could
///      admit a market under a strict route and relax the route the next day.
contract CotejoOracleAdapter is ICotejoOracleAdapter {
    using MathLib for uint256;

    /// @inheritdoc ICotejoOracleAdapter
    uint256 public constant override PRICE_SCALE = 1e36;

    uint256 private constant WAD = 1e18;

    IPriceRouter public immutable ROUTER;

    bytes32 private immutable _collateralAsset;
    bytes32 private immutable _loanAsset;
    uint8 private immutable _collateralDecimals;
    uint8 private immutable _loanDecimals;

    // R8 snapshots, one per route.
    uint8 private immutable _colMinSources;
    uint16 private immutable _colMaxDeviationBps;
    uint8 private immutable _colDistinctGroups;
    uint8 private immutable _loanMinSources;
    uint16 private immutable _loanMaxDeviationBps;
    uint8 private immutable _loanDistinctGroups;

    /// @param router_ Cotejo price router.
    /// @param collateralAsset_ Asset identifier of the collateral, e.g. `keccak256("WBT/USD")`.
    /// @param loanAsset_ Asset identifier of the loan token.
    /// @param collateralDecimals_ Decimals of the collateral ERC-20.
    /// @param loanDecimals_ Decimals of the loan ERC-20.
    constructor(
        address router_,
        bytes32 collateralAsset_,
        bytes32 loanAsset_,
        uint8 collateralDecimals_,
        uint8 loanDecimals_
    ) {
        if (router_ == address(0) || collateralAsset_ == bytes32(0) || loanAsset_ == bytes32(0)) {
            revert MarketErrors.Market__InvalidParameter();
        }
        if (collateralAsset_ == loanAsset_) revert MarketErrors.Market__InvalidParameter();

        ROUTER = IPriceRouter(router_);
        _collateralAsset = collateralAsset_;
        _loanAsset = loanAsset_;
        _collateralDecimals = collateralDecimals_;
        _loanDecimals = loanDecimals_;

        (_colMinSources, _colMaxDeviationBps, _colDistinctGroups) = _readPolicy(collateralAsset_);
        (_loanMinSources, _loanMaxDeviationBps, _loanDistinctGroups) = _readPolicy(loanAsset_);
    }

    // --------------------------------------------------------------------------------
    // Price
    // --------------------------------------------------------------------------------

    /// @inheritdoc ICotejoOracleAdapter
    function price() external view override returns (uint256) {
        _enforcePolicy(_collateralAsset, _colMinSources, _colMaxDeviationBps, _colDistinctGroups);
        _enforcePolicy(_loanAsset, _loanMinSources, _loanMaxDeviationBps, _loanDistinctGroups);

        // Both reads propagate Cotejo's typed error on refusal. That propagation is the
        // degraded-mode trigger: the market never receives a substitute value.
        (uint256 colUsd, uint8 colDec,) = ROUTER.latestPrice(_collateralAsset);
        (uint256 loanUsd, uint8 loanDec,) = ROUTER.latestPrice(_loanAsset);

        // Normalise both USD prices to WAD before dividing, so the ratio does not inherit a
        // scale difference between the two routes.
        uint256 colWad = _toWad(colUsd, colDec);
        uint256 loanWad = _toWad(loanUsd, loanDec);
        if (loanWad == 0) revert MarketErrors.Market__InvalidParameter();

        // price = (collateralUsd / loanUsd) * 10^loanDecimals / 10^collateralDecimals * SCALE,
        // so that: loanValue = collateralAmount * price / PRICE_SCALE.
        uint256 ratio = colWad.mulDivDown(PRICE_SCALE, loanWad);
        return ratio.mulDivDown(10 ** _loanDecimals, 10 ** _collateralDecimals);
    }

    /// @inheritdoc ICotejoOracleAdapter
    function loanPriceUsd() external view override returns (uint256) {
        _enforcePolicy(_loanAsset, _loanMinSources, _loanMaxDeviationBps, _loanDistinctGroups);
        (uint256 loanUsd, uint8 loanDec,) = ROUTER.latestPrice(_loanAsset);
        return _toWad(loanUsd, loanDec);
    }

    // --------------------------------------------------------------------------------
    // Depth (M1)
    // --------------------------------------------------------------------------------

    /// @inheritdoc ICotejoOracleAdapter
    /// @dev Second-lowest on each route, then the smaller of the two. See `_routeDepth` for
    ///      why the statistic is the second-lowest rather than the minimum.
    function bindingDepthUsd() external view override returns (uint256) {
        uint256 collateralDepth = _routeDepth(_collateralAsset);
        uint256 loanDepth = _routeDepth(_loanAsset);
        return MathLib.min(collateralDepth, loanDepth);
    }

    /// @dev Second-lowest, not lowest. The trade is exact and it is not a free win:
    ///
    ///        lowest        — one honest reporter holds the ceiling down,
    ///                        but one malicious reporter drives it to zero and blocks
    ///                        every borrow on the route.
    ///        second-lowest — two liars are needed to inflate it, and two to deny it.
    ///
    ///      Giving up "one honest reporter is enough" is only acceptable because
    ///      `MAX_ADAPTER_DEBT_USD` bounds the loss without consulting any reporter at all.
    ///      The two ship together or not at all.
    ///
    ///      The reading comes from `ROUTER.latestDepth`, so it carries the pause check, the
    ///      quorum, the operator-independence rule and the spread tolerance that produced the
    ///      price. Depth used to be read straight off the sources with only a staleness
    ///      filter, which made the two sets identical by coincidence rather than by rule.
    function _routeDepth(bytes32 asset) private view returns (uint256) {
        (, uint256 secondLowest,) = ROUTER.latestDepth(asset);
        return secondLowest;
    }

    // --------------------------------------------------------------------------------
    // Policy (R8)
    // --------------------------------------------------------------------------------

    /// @inheritdoc ICotejoOracleAdapter
    function deviationCombined() external view override returns (uint256) {
        return (uint256(_colMaxDeviationBps) + uint256(_loanMaxDeviationBps)) * WAD / 10_000;
    }

    /// @inheritdoc ICotejoOracleAdapter
    function policySnapshot(bytes32 asset)
        external
        view
        override
        returns (uint8 minSources, uint16 maxDeviationBps, uint8 distinctGroups)
    {
        if (asset == _collateralAsset) {
            return (_colMinSources, _colMaxDeviationBps, _colDistinctGroups);
        }
        if (asset == _loanAsset) return (_loanMinSources, _loanMaxDeviationBps, _loanDistinctGroups);
        revert MarketErrors.Market__InvalidParameter();
    }

    /// @dev Reverts if the live route is weaker than the snapshot on any axis. "Weaker" means
    ///      a smaller quorum, a wider tolerance, or fewer distinct operators.
    function _enforcePolicy(bytes32 asset, uint8 minSources, uint16 maxDevBps, uint8 groups) private view {
        (uint8 liveMin, uint16 liveDev, uint8 liveGroups) = _readPolicy(asset);
        if (liveMin < minSources || liveDev > maxDevBps || liveGroups < groups) {
            revert MarketErrors.Market__R8_RoutePolicyWeakened(asset);
        }
    }

    function _readPolicy(bytes32 asset)
        private
        view
        returns (uint8 minSources, uint16 maxDeviationBps, uint8 distinctGroups)
    {
        IPriceRouter.Route memory route = ROUTER.getRoute(asset);
        if (route.sources.length == 0) {
            revert MarketErrors.Market__R1_InsufficientRouteQuorum(asset, 0, 3);
        }
        return (route.minSources, route.maxDeviationBps, _countDistinctGroups(asset, route));
    }

    /// @dev O(n^2) over at most 15 sources, matching the router's own cap.
    function _countDistinctGroups(bytes32 asset, IPriceRouter.Route memory route)
        private
        view
        returns (uint8 distinct)
    {
        uint256 n = route.sources.length;
        bytes32[] memory seen = new bytes32[](n);

        for (uint256 i; i < n; ++i) {
            bytes32 group = IPriceSource(route.sources[i]).operatorGroupOf(asset);
            bool duplicate;
            for (uint256 j; j < distinct; ++j) {
                if (seen[j] == group) {
                    duplicate = true;
                    break;
                }
            }
            if (!duplicate) {
                seen[distinct] = group;
                unchecked {
                    ++distinct;
                }
            }
        }
    }

    // --------------------------------------------------------------------------------
    // Introspection
    // --------------------------------------------------------------------------------

    function router() external view override returns (address) {
        return address(ROUTER);
    }

    function collateralAsset() external view override returns (bytes32) {
        return _collateralAsset;
    }

    function loanAsset() external view override returns (bytes32) {
        return _loanAsset;
    }

    function collateralTokenDecimals() external view override returns (uint8) {
        return _collateralDecimals;
    }

    function loanTokenDecimals() external view override returns (uint8) {
        return _loanDecimals;
    }

    function _toWad(uint256 value, uint8 decimals) private pure returns (uint256) {
        if (decimals == 18) return value;
        return decimals < 18 ? value * (10 ** (18 - decimals)) : value / (10 ** (decimals - 18));
    }
}
