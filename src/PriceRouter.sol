// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {IPriceRouter} from "./interfaces/IPriceRouter.sol";
import {IPriceSource} from "./interfaces/IPriceSource.sol";
import {AggregationLib} from "./libraries/AggregationLib.sol";
import {CotejoErrors} from "./libraries/CotejoErrors.sol";

/// @title PriceRouter
/// @notice Entry point for aggregated prices. Safe because it refuses to answer, not
///         because it answers well.
///
/// @dev The read path never returns a stale price, never returns zero, and never returns a
///      default. Every failure is a typed revert. There is no function on this contract, at
///      any access level, that writes a price (INV-7) — prices exist only as the output of
///      aggregating live source reads, and the only stored state is routing configuration.
///
///      Two failure modes are treated differently on purpose:
///
///        - A source that *reverts* is unavailable. It is dropped from the set and INV-1
///          decides whether enough sources remain. Otherwise a single griefing source could
///          deny the asset to everyone, and denying a liquidator is itself a loss.
///        - A source that *answers with a stale observation* is a signal that something is
///          wrong upstream, not a source that is merely absent. It reverts the whole read
///          under INV-3, for any source in the set.
///
///      Each source call is capped at `SOURCE_GAS_LIMIT`. Without a cap, a malicious source
///      could burn everything forwarded to it and, under the 63/64 rule, leave the router
///      too little gas to finish — turning `try/catch` into a denial vector rather than a
///      defence against one.
///
///      On `block.timestamp`. INV-3 is a statement about wall-clock age, so the staleness
///      check has no alternative clock to read; the linter flags every such comparison and
///      each one is intentional here. On Whitechain the L2 timestamp is set by the
///      sequencer rather than by a validator auction, blocks land every second, and the
///      value is monotonic — so the manipulation the warning describes would mean a
///      compromised sequencer, at which point a few seconds of drift on a staleness window
///      measured in minutes is not the problem worth defending against. Routes should still
///      be configured with windows well above the granularity an operator could plausibly
///      shift.
contract PriceRouter is IPriceRouter, Ownable2Step {
    using AggregationLib for uint256[];

    /// @notice Decimals every aggregated price is reported in.
    uint8 public constant ROUTER_DECIMALS = 18;

    /// @notice Gas forwarded to each source read.
    /// @dev Generous for a storage read plus a little arithmetic, tight enough that fifteen
    ///      hostile sources cannot exhaust a normal transaction.
    uint256 public constant SOURCE_GAS_LIMIT = 200_000;

    /// @notice Hard cap on sources per route (D4).
    uint8 public constant MAX_SOURCES_PER_ROUTE = AggregationLib.MAX_SOURCES_PER_ROUTE;

    /// @dev One source's contribution to a read. Passed around as a memory struct rather
    ///      than a four-value tuple: a tuple occupies four stack slots at every call site
    ///      and pushes `latestPrice` past the EVM's reachable depth, while a struct costs
    ///      one pointer.
    struct SourceRead {
        bool usable;
        uint256 price;
        uint256 observedAt;
        bytes32 group;
        uint256 depthUsd;
    }

    /// @dev The usable subset of a route's sources, normalised and ready to aggregate.
    struct FreshSet {
        uint256[] prices;
        bytes32[] groups;
        uint256[] depths;
        uint256 oldest;
    }

    address private _governor;

    mapping(bytes32 asset => Route route) private _routes;
    mapping(bytes32 asset => bool paused) private _paused;
    mapping(address guardian => bool active) private _guardians;
    mapping(bytes32 asset => address token) private _assetToken;

    /// @notice The governor was set. Emitted once, at bootstrap.
    event GovernorSet(address indexed governor);

    /// @notice A guardian was added or removed.
    event GuardianSet(address indexed guardian, bool active);

    /// @notice An asset identifier was bound to the ERC-20 it prices. Emitted once per asset.
    event AssetTokenRegistered(bytes32 indexed asset, address indexed token);

    /// @dev Restricts to the RouteGovernor, which owns the timelock.
    modifier onlyGovernor() {
        if (msg.sender != _governor) revert CotejoErrors.Cotejo__OnlyGovernor(msg.sender);
        _;
    }

    /// @param owner_ Bootstrap owner. Its only power is setting the governor once.
    constructor(address owner_) Ownable(owner_) {}

    // --------------------------------------------------------------------------------
    // Read path
    // --------------------------------------------------------------------------------

    /// @inheritdoc IPriceRouter
    function latestPrice(bytes32 asset)
        external
        view
        override
        returns (uint256 price, uint8 decimals, uint256 observedAt)
    {
        FreshSet memory set = _validatedSet(asset, false);
        return (set.prices.median(), ROUTER_DECIMALS, set.oldest);
    }

    /// @inheritdoc IPriceRouter
    /// @dev Depth is aggregated over **exactly** the set that produced the price: same pause
    ///      check, same quorum, same operator-independence rule, same spread tolerance. Before
    ///      this existed, a consumer read depth straight off the sources with only a staleness
    ///      filter, so it could compute a debt ceiling from a set this router would have
    ///      refused to price from. The two paths were identical only by coincidence, and a
    ///      coincidence is not a guarantee.
    ///
    ///      Returns the two smallest depths so the caller can pick its own robustness point.
    ///      The lowest is immune to inflation but lets one malicious reporter drive it to
    ///      zero; the second-lowest needs two liars to inflate and two to deny. Cotejo's
    ///      market takes the second-lowest, backed by a report-independent ceiling.
    function latestDepth(bytes32 asset)
        external
        view
        override
        returns (uint256 lowestUsd, uint256 secondLowestUsd, uint8 count)
    {
        FreshSet memory set = _validatedSet(asset, true);

        lowestUsd = type(uint256).max;
        secondLowestUsd = type(uint256).max;

        uint256 n = set.depths.length;
        for (uint256 i; i < n; ++i) {
            uint256 d = set.depths[i];
            if (d < lowestUsd) {
                secondLowestUsd = lowestUsd;
                lowestUsd = d;
            } else if (d < secondLowestUsd) {
                secondLowestUsd = d;
            }
        }

        // A single-source set has no second-lowest. Report zero rather than a sentinel: zero
        // propagates to a zero ceiling, which is the fail-closed direction.
        if (n < 2) secondLowestUsd = 0;
        if (n == 0) lowestUsd = 0;

        // casting to 'uint8' is safe because the fresh set can never exceed
        // MAX_SOURCES_PER_ROUTE (15), enforced when the route is validated.
        // forge-lint: disable-next-line(unsafe-typecast)
        return (lowestUsd, secondLowestUsd, uint8(n));
    }

    /// @dev Pause, quorum, operator independence and spread — the whole gate, in one place.
    ///      Both public read paths go through it, which is what makes the depth set and the
    ///      price set the same set by construction rather than by parallel maintenance.
    function _validatedSet(bytes32 asset, bool withDepth) private view returns (FreshSet memory set) {
        if (_paused[asset]) revert CotejoErrors.Cotejo__Paused(asset);

        Route storage route = _routes[asset];
        if (route.sources.length == 0) revert CotejoErrors.Cotejo__RouteNotConfigured(asset);

        set = _collectFresh(asset, route, withDepth);

        // INV-1
        if (set.prices.length < route.minSources) {
            revert CotejoErrors.Cotejo__InsufficientSources(asset, set.prices.length, route.minSources);
        }

        _enforceOperatorIndependence(asset, set.groups, route.maxSourcesPerOperatorGroup);

        set.prices.sortInPlace();

        // INV-2, measured against the median (D1).
        uint256 spreadBps = set.prices.deviationBps();
        if (spreadBps > route.maxDeviationBps) {
            revert CotejoErrors.Cotejo__DeviationExceeded(asset, spreadBps, route.maxDeviationBps);
        }
    }

    /// @dev Reads every source in the route and returns the usable subset, already
    ///      normalised to `ROUTER_DECIMALS`, alongside each entry's operator group and the
    ///      oldest observation in the set.
    ///
    ///      Split out of `latestPrice` to keep both within the EVM's reachable stack depth.
    ///      The alternative was compiling the whole project through the IR pipeline, which
    ///      is a large change to the produced bytecode for a local readability problem.
    function _collectFresh(bytes32 asset, Route storage route, bool withDepth)
        private
        view
        returns (FreshSet memory out)
    {
        uint256 total = route.sources.length;
        uint256[] memory prices = new uint256[](total);
        bytes32[] memory allGroups = new bytes32[](total);
        uint256[] memory allDepths = new uint256[](total);
        uint256 fresh;
        out.oldest = type(uint256).max;

        for (uint256 i; i < total; ++i) {
            SourceRead memory read =
                _readSource(route.sources[i], asset, route.maxStalenessSeconds, withDepth);
            if (!read.usable) continue;

            prices[fresh] = read.price;
            allGroups[fresh] = read.group;
            allDepths[fresh] = read.depthUsd;
            unchecked {
                ++fresh;
            }
            if (read.observedAt < out.oldest) out.oldest = read.observedAt;
        }

        out.prices = new uint256[](fresh);
        out.groups = new bytes32[](fresh);
        out.depths = new uint256[](fresh);
        for (uint256 i; i < fresh; ++i) {
            out.prices[i] = prices[i];
            out.groups[i] = allGroups[i];
            out.depths[i] = allDepths[i];
        }
    }

    /// @dev Reads one source. Returns `usable == false` when the source is unavailable or
    ///      unusable, and reverts outright when it answers with a stale observation (INV-3).
    ///
    ///      The staleness revert lives in the success branch of the `try`, so it propagates
    ///      to the caller rather than being swallowed by the `catch` — `catch` only sees
    ///      reverts raised by the external call itself.
    function _readSource(address source, bytes32 asset, uint32 maxStaleness, bool withDepth)
        private
        view
        returns (SourceRead memory out)
    {
        try IPriceSource(source).latestPrice{gas: SOURCE_GAS_LIMIT}(asset) returns (
            uint256 p, uint8 d, uint256 obsAt, bytes32 g
        ) {
            // A source claiming to have seen the future is malfunctioning, not stale. Drop
            // it rather than reverting, so one bad clock cannot brick the asset.
            if (obsAt > block.timestamp) return out;

            // INV-3. Subtraction is safe: the branch above established obsAt <= now.
            unchecked {
                if (block.timestamp - obsAt > maxStaleness) {
                    revert CotejoErrors.Cotejo__StalePrice(asset, source, obsAt, maxStaleness);
                }
            }

            // A zero price never reaches aggregation. Sources reject it; this is the
            // backstop for one that does not.
            if (p == 0) return out;

            out.usable = true;
            out.price = AggregationLib.normalize(p, d, ROUTER_DECIMALS);
            out.observedAt = obsAt;
            out.group = g;

            // The extra staticcall is skipped on the price path, which is the one every
            // Chainlink-shaped consumer hits through `latestRoundData`. A source that cannot
            // answer contributes zero depth, and zero closes the ceiling rather than opening
            // it — so a failure here costs liveness, never safety.
            if (withDepth) {
                try IPriceSource(source).latestDepthUsd{gas: SOURCE_GAS_LIMIT}(asset) returns (
                    uint256 depth
                ) {
                    out.depthUsd = depth;
                } catch {
                    out.depthUsd = 0;
                }
            }
        } catch {
            // Unavailable. INV-1 decides whether the remaining set is enough.
            return out;
        }
    }

    /// @dev INV-5, re-checked at read time because a source's operator group can change
    ///      after the route was committed. Evaluated over the fresh set, since that is what
    ///      actually produces the price; the full configured set is checked again whenever a
    ///      route is validated.
    function _enforceOperatorIndependence(bytes32 asset, bytes32[] memory groups, uint256 maxPerGroup)
        private
        pure
    {
        uint256 n = groups.length;
        for (uint256 i; i < n; ++i) {
            uint256 shared;
            for (uint256 j; j < n; ++j) {
                if (groups[j] == groups[i]) {
                    unchecked {
                        ++shared;
                    }
                }
            }
            if (shared > maxPerGroup) {
                revert CotejoErrors.Cotejo__OperatorConcentration(asset, groups[i], shared, maxPerGroup);
            }
        }
    }

    /// @inheritdoc IPriceRouter
    function getRoute(bytes32 asset) external view override returns (Route memory route) {
        return _routes[asset];
    }

    /// @inheritdoc IPriceRouter
    function isPaused(bytes32 asset) external view override returns (bool paused) {
        return _paused[asset];
    }

    /// @inheritdoc IPriceRouter
    function governor() external view override returns (address) {
        return _governor;
    }

    /// @notice Whether `account` may pause assets.
    function isGuardian(address account) external view returns (bool active) {
        return _guardians[account];
    }

    /// @notice The ERC-20 token an asset identifier prices, or the zero address if unbound.
    /// @dev Consumers that hold the token — a lending market, say — use this to prove that
    ///      the feed they validated is the feed for the asset they actually custody. Without
    ///      it, checking a route's quorum and operator spread proves nothing about which
    ///      token that route describes.
    function tokenForAsset(bytes32 asset) external view override returns (address token) {
        return _assetToken[asset];
    }

    /// @notice Validates a route without committing it.
    /// @dev One definition of a valid route, used by `commitRoute` here and by
    ///      `RouteGovernor.proposeRoute` at proposal time, so the two can never disagree.
    ///      Reverts on the first violation found.
    ///
    ///      The INV-5 check here covers every configured source, not just the fresh ones, so
    ///      a route that could only ever be served by a single operator is rejected before
    ///      it is ever committed.
    /// @param asset Asset the route is for.
    /// @param route Route to validate.
    function validateRoute(bytes32 asset, Route calldata route) public view override {
        uint256 count = route.sources.length;
        if (count == 0 || route.minSources == 0) revert CotejoErrors.Cotejo__EmptyRoute();
        if (count > MAX_SOURCES_PER_ROUTE) {
            revert CotejoErrors.Cotejo__TooManySources(count, MAX_SOURCES_PER_ROUTE);
        }
        if (route.minSources > count) {
            revert CotejoErrors.Cotejo__MinSourcesUnreachable(route.minSources, count);
        }
        if (
            route.maxDeviationBps == 0 || route.maxStalenessSeconds == 0
                || route.reporterHeartbeatSeconds == 0 || route.maxSourcesPerOperatorGroup == 0
        ) {
            revert CotejoErrors.Cotejo__InvalidRouteParameter();
        }

        // D2: a staleness window shorter than two heartbeats makes normal operation revert
        // at random and leaves nobody able to explain why.
        if (uint256(route.maxStalenessSeconds) < 2 * uint256(route.reporterHeartbeatSeconds)) {
            revert CotejoErrors.Cotejo__StalenessBelowHeartbeat(
                route.maxStalenessSeconds, route.reporterHeartbeatSeconds
            );
        }

        for (uint256 i; i < count; ++i) {
            address source = route.sources[i];
            if (source == address(0)) revert CotejoErrors.Cotejo__InvalidRouteParameter();

            for (uint256 j; j < i; ++j) {
                if (route.sources[j] == source) revert CotejoErrors.Cotejo__DuplicateSource(source);
            }

            if (!IPriceSource(source).supportsAsset(asset)) {
                revert CotejoErrors.Cotejo__SourceDoesNotServeAsset(source, asset);
            }
        }

        // INV-5 at configuration time, across every configured source.
        for (uint256 i; i < count; ++i) {
            bytes32 group = IPriceSource(route.sources[i]).operatorGroupOf(asset);
            uint256 shared;
            for (uint256 j; j < count; ++j) {
                if (IPriceSource(route.sources[j]).operatorGroupOf(asset) == group) {
                    unchecked {
                        ++shared;
                    }
                }
            }
            if (shared > route.maxSourcesPerOperatorGroup) {
                revert CotejoErrors.Cotejo__OperatorConcentration(
                    asset, group, shared, route.maxSourcesPerOperatorGroup
                );
            }
        }
    }

    // --------------------------------------------------------------------------------
    // Governance-driven writes. None of these writes a price (INV-7).
    // --------------------------------------------------------------------------------

    /// @inheritdoc IPriceRouter
    /// @dev Re-validates at execution time. A route that was sound when proposed can have
    ///      drifted during the 48h wait — a source's operator group can move — and the
    ///      correct response is to fail the commit, not to install a route that violates
    ///      INV-5 the moment it lands.
    function commitRoute(bytes32 asset, Route calldata route) external override onlyGovernor {
        validateRoute(asset, route);
        _routes[asset] = route;
        emit RouteCommitted(asset, route.sources, route.minSources);
    }

    /// @inheritdoc IPriceRouter
    /// @dev INV-6. Immediate, and available to any guardian: pausing only ever moves the
    ///      system towards refusing to answer, which is the safe direction.
    function pause(bytes32 asset) external override {
        if (!_guardians[msg.sender]) revert CotejoErrors.Cotejo__OnlyGuardian(msg.sender);
        _paused[asset] = true;
        emit Paused(asset, msg.sender);
    }

    /// @inheritdoc IPriceRouter
    /// @dev INV-6. Governor only, and the governor will not call this until its own 48h
    ///      timelock has elapsed. Unpausing resumes answering, so it takes the long path.
    function unpause(bytes32 asset) external override onlyGovernor {
        if (!_paused[asset]) revert CotejoErrors.Cotejo__NotPaused(asset);
        _paused[asset] = false;
        emit Unpaused(asset);
    }

    /// @notice Adds or removes a guardian.
    /// @dev Governor-controlled, so changing who can pause goes through the same
    ///      administrative path as everything else.
    function setGuardian(address guardian, bool active) external override onlyGovernor {
        if (guardian == address(0)) revert CotejoErrors.Cotejo__InvalidRouteParameter();
        _guardians[guardian] = active;
        emit GuardianSet(guardian, active);
    }

    /// @notice Binds an asset identifier to the ERC-20 token it prices.
    /// @dev **Append-only, by necessity.** Once an asset id is bound it can never be rebound
    ///      or cleared. If governance could remap `keccak256("WBT/USD")` to a different
    ///      token, every market created under the old mapping would keep custody of one asset
    ///      while pricing another — silently, with no invariant tripping. A registry that can
    ///      be rewritten turns every check that depends on it into decoration.
    ///
    ///      Registering a *new* asset cannot affect any existing market, so this needs no
    ///      timelock. Rewriting one would, which is why it is impossible instead.
    /// @param asset Identifier, e.g. `keccak256("WBT/USD")`.
    /// @param token ERC-20 the identifier prices.
    function registerAssetToken(bytes32 asset, address token) external override onlyGovernor {
        if (asset == bytes32(0) || token == address(0)) {
            revert CotejoErrors.Cotejo__InvalidRouteParameter();
        }
        address existing = _assetToken[asset];
        if (existing != address(0)) {
            revert CotejoErrors.Cotejo__AssetAlreadyRegistered(asset, existing);
        }
        _assetToken[asset] = token;
        emit AssetTokenRegistered(asset, token);
    }

    /// @notice Binds the router to its governor. Callable once, by the bootstrap owner.
    /// @dev Router and governor reference each other, so one has to be deployed first. This
    ///      closes the loop and then cannot be used again: after it is set, the owner has no
    ///      remaining power over routing, pausing, or prices.
    function setGovernor(address governor_) external onlyOwner {
        if (governor_ == address(0)) revert CotejoErrors.Cotejo__InvalidRouteParameter();
        if (_governor != address(0)) revert CotejoErrors.Cotejo__InvalidRouteParameter();
        _governor = governor_;
        emit GovernorSet(governor_);
    }
}
