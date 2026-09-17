// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ICotejoMarket} from "./interfaces/ICotejoMarket.sol";
import {ICotejoOracleAdapter} from "./interfaces/ICotejoOracleAdapter.sol";
import {IIrm} from "./interfaces/IIrm.sol";
import {Id, MarketParams, Market, Position, DepthAnchor, PriceAnchor} from "./types/MarketTypes.sol";
import {MarketErrors} from "./libraries/MarketErrors.sol";
import {MathLib} from "./libraries/MathLib.sol";
import {SharesMathLib} from "./libraries/SharesMathLib.sol";
import {IPriceRouter} from "../interfaces/IPriceRouter.sol";
import {IPriceSource} from "../interfaces/IPriceSource.sol";

/// @title CotejoMarket
/// @notice Isolated lending markets over the Cotejo oracle.
///
/// @dev Built against one incident. On 30 August 2026 Tectonic lost 75M because a thinly
///      traded collateral with a 20% factor was pumped 100x in twenty minutes, and because the
///      capital behind every market was the same pool. Three properties of this contract
///      answer that directly: markets share nothing, a collateral that cannot be priced
///      independently cannot be admitted, and a market cannot owe more than its liquidators
///      could plausibly unwind.
///
///      **Degraded mode is the load-bearing decision.** When the oracle refuses to answer,
///      this contract blocks liquidation. That is not a safety valve failing open — it is the
///      point. In Tectonic the liquidation machinery worked perfectly; the attacker used it,
///      feeding inflated collateral into a mechanism that dutifully handed back good assets.
///      Blocking liquidation trades temporary bad debt, which is bounded and socialised among
///      one market's suppliers, for an irreversible transfer to whoever manufactured the lie.
///      **A5.2 — why a reentrancy guard.** `IIrm.borrowRate` is non-`view` and sits on every
///      state-changing path, so a whitelisted model holds a reentrancy foothold in the middle
///      of `borrow` and `liquidate`. The only thing preventing that today is trust in the
///      whitelist, which is exactly what the whitelist-capture threat assumes is gone. The
///      guard is storage-based rather than transient because the deployment targets `shanghai`.
contract CotejoMarket is ICotejoMarket, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using MathLib for uint256;
    using SharesMathLib for uint256;

    uint256 internal constant WAD = 1e18;

    /// @notice R3. No market may be created above this loan-to-value.
    uint256 public constant MAX_LLTV = 0.86e18;

    /// @notice R1. Minimum quorum a backing route must require.
    uint8 public constant MIN_ROUTE_QUORUM = 3;

    /// @notice R2. Minimum distinct operator groups a backing route must span.
    uint8 public constant MIN_DISTINCT_GROUPS = 3;

    /// @notice R7. A backing route must carry this much redundancy beyond its own quorum.
    /// @dev Without it, one reporter outage drops the route below quorum, the oracle refuses,
    ///      and — because degraded mode blocks liquidation — the market's entire solvency
    ///      control freezes. That turns a routine operational incident into a safety incident,
    ///      and hands an underwater borrower a cheap way to stop their own liquidation.
    uint8 public constant ROUTE_REDUNDANCY = 2;

    /// @notice Absolute ceiling on the liquidation incentive, independent of R5.
    /// @dev R5 bounds the incentive so that a liquidation cannot extract value through the
    ///      largest price error a route tolerates. It says nothing about gouging the borrower:
    ///      at a 50% LLTV the R5 formula permits a 96% bonus. This is the borrower-protection
    ///      half, and it is a different concern from oracle risk rather than a restatement of
    ///      it. The effective bound is `min(R5 formula, this)`.
    uint256 public constant MAX_LIF_ABSOLUTE = 1.15e18;

    /// @notice A liquidation may repay at most half of a position's debt.
    uint256 public constant CLOSE_FACTOR = 0.5e18;

    /// @notice M5. Ceiling applied to whatever the IRM returns, per second.
    /// @dev ~800% APR. With `IRM_GAS_LIMIT` and the surrounding `try/catch`, this is the whole
    ///      bound on a compromised whitelist entry: it can make borrowing expensive inside this
    ///      ceiling, and it can fail, but it can neither drain nor freeze.
    uint256 public constant MAX_BORROW_RATE = 2.6e11;

    /// @notice A5.3. Wait before a newly proposed interest rate model can be used.
    uint256 public constant IRM_TIMELOCK = 48 hours;

    /// @notice A5.1. Gas forwarded to the interest rate model.
    uint256 public constant IRM_GAS_LIMIT = 150_000;

    /// @notice M1. Depth may not grow faster than this, in basis points per hour.
    uint256 public constant DEPTH_GROWTH_BPS_PER_HOUR = 2_500;

    /// @notice Wall-clock time credited to any single depth refresh.
    /// @dev Without this the growth clamp evaporates. The anchor only advanced on `borrow`, so
    ///      after a quiet week `elapsed` was 604 800s and the permitted ceiling was ~42x the
    ///      anchor — no clamp at all. Capped at four hours, one refresh can at most double the
    ///      anchor, and a larger rise needs several refreshes separated by real time, each a
    ///      public transaction someone can watch.
    uint256 public constant DEPTH_CLAMP_MAX_ELAPSED = 4 hours;

    /// @notice A1.2. Fraction of the depth anchor retained when a liquidation leaves bad debt.
    /// @dev Bad debt is on-chain proof that the reported depth was not there. This is the only
    ///      feedback in the system that checks a reporter's claim against something they do not
    ///      control — it is after the fact, but it is ground truth.
    uint256 public constant BAD_DEBT_DEPTH_HAIRCUT_BPS = 5_000;

    /// @notice A3. Instantaneous tolerance before the upward breaker trips, in bps.
    uint256 public constant PRICE_BAND_FLOOR_BPS = 500;

    /// @notice A3. How much further the band opens per hour since the anchor, in bps.
    uint256 public constant PRICE_BAND_BPS_PER_HOUR = 2_000;

    /// @notice A3. Hard ceiling on the band, reached after roughly 2.25 hours.
    uint256 public constant MAX_PRICE_BAND_BPS = 5_000;

    /// @notice A2. Continuous degradation before the wind-down path opens.
    uint256 public constant DEGRADED_GRACE = 72 hours;

    /// @notice A2. Time over which the wind-down premium ramps to its maximum.
    uint256 public constant DEGRADED_PREMIUM_RAMP = 7 days;

    /// @notice A2. Largest premium a degraded wind-down can pay, in bps.
    uint256 public constant DEGRADED_PREMIUM_MAX_BPS = 1_000;

    /// @notice Markets that may share one oracle adapter.
    /// @dev Bounds the cost of the adapter-level aggregate below, which is a loop.
    uint256 public constant MAX_MARKETS_PER_ADAPTER = 8;

    /// @notice Fraction of observed depth an adapter's markets may owe in total, in bps.
    /// @dev Immutable for the deployment rather than governable. A lever that raises every
    ///      market's debt ceiling at once is precisely the lever an attacker wants.
    uint256 public immutable DEPTH_MULTIPLIER_BPS;

    /// @notice A1.1. Hard ceiling on one adapter's total debt, in whole USD, independent of
    ///         anything a reporter says.
    /// @dev The load-bearing defence against a colluding reporter set, and the only mechanism
    ///      in the design whose guarantee does not depend on any reporter being honest. Under
    ///      total collusion it converts an unbounded loss into a bounded one. It cannot stop
    ///      the attack; it caps what the attack is worth.
    uint256 public immutable MAX_ADAPTER_DEBT_USD;

    mapping(Id id => Market) private _market;
    mapping(Id id => MarketParams) private _params;
    mapping(Id id => mapping(address user => Position)) private _position;
    mapping(address irm => bool allowed) private _irmWhitelist;
    mapping(address irm => uint64 eta) private _pendingIrm;

    /// @dev Depth is a property of the oracle routes, not of any one market, so the anchor is
    ///      keyed by adapter. Keying it per market let N markets each advance their own copy
    ///      independently, which is half of why the cap was defeatable by creating markets.
    mapping(address adapter => DepthAnchor) private _depthAnchor;

    /// @dev A3. Rate-limited recording of the adapter's own output. Subject to INV-7': it
    ///      gates and bounds, it never sizes anything.
    mapping(address adapter => PriceAnchor) private _priceAnchor;

    /// @dev A2. When this adapter last stopped answering, or zero while it is healthy.
    mapping(address adapter => uint64 since) private _degradedSince;

    /// @dev Every market sharing an adapter, so the ceiling can bind across all of them.
    mapping(address adapter => Id[] ids) private _adapterMarkets;

    /// @notice Governance ratchet, per market. Starts unbounded and only ever decreases.
    mapping(Id id => uint128 ceiling) private _hardCeiling;

    /// @param owner_ Controls the IRM whitelist and the debt ratchet. It cannot touch any
    ///        market parameter, raise any ceiling, or write a price.
    /// @param depthMultiplierBps Fraction of observed depth an adapter may owe. 5000 = half.
    /// @param maxAdapterDebtUsd Hard ceiling per adapter, in whole USD.
    constructor(address owner_, uint256 depthMultiplierBps, uint256 maxAdapterDebtUsd) Ownable(owner_) {
        if (depthMultiplierBps == 0 || depthMultiplierBps > 10_000 || maxAdapterDebtUsd == 0) {
            revert MarketErrors.Market__InvalidParameter();
        }
        DEPTH_MULTIPLIER_BPS = depthMultiplierBps;
        MAX_ADAPTER_DEBT_USD = maxAdapterDebtUsd;
    }

    // --------------------------------------------------------------------------------
    // Creation
    // --------------------------------------------------------------------------------

    /// @inheritdoc ICotejoMarket
    function createMarket(MarketParams calldata params, uint256 liquidationIncentiveFactor)
        external
        override
        nonReentrant
        returns (Id id)
    {
        id = _id(params);
        if (_market[id].lastUpdate != 0) revert MarketErrors.Market__AlreadyCreated(id);

        if (
            params.collateralToken == address(0) || params.loanToken == address(0)
                || params.collateralToken == params.loanToken || params.oracleAdapter == address(0)
        ) revert MarketErrors.Market__InvalidParameter();

        // R3
        if (params.lltv > MAX_LLTV) revert MarketErrors.Market__R3_LltvTooHigh(params.lltv, MAX_LLTV);
        if (params.lltv == 0) revert MarketErrors.Market__InvalidParameter();

        // R4
        if (!_irmWhitelist[params.irm]) revert MarketErrors.Market__R4_IrmNotWhitelisted(params.irm);

        ICotejoOracleAdapter adapter = ICotejoOracleAdapter(params.oracleAdapter);

        // R1, R2, R6, R7 on both routes. Both, because a manipulated loan-token price moves
        // every solvency check just as surely as a manipulated collateral price does.
        _validateRoute(adapter, adapter.collateralAsset(), params.collateralToken);
        _validateRoute(adapter, adapter.loanAsset(), params.loanToken);

        // R5
        uint256 derivedMax = _maxIncentive(adapter.deviationCombined(), params.lltv);
        uint256 bound = MathLib.min(derivedMax, MAX_LIF_ABSOLUTE);
        if (liquidationIncentiveFactor > bound) {
            revert MarketErrors.Market__R5_IncentiveTooHigh(liquidationIncentiveFactor, bound);
        }
        if (liquidationIncentiveFactor < WAD) revert MarketErrors.Market__InvalidParameter();

        // F2. Record the market against its adapter so the depth ceiling can bind across every
        // market that shares it. Creation stays permissionless — the defence is that the
        // ceiling is shared, not that creation is gated — but the list is bounded so the
        // aggregate loop cannot be made expensive.
        Id[] storage siblings = _adapterMarkets[params.oracleAdapter];
        if (siblings.length >= MAX_MARKETS_PER_ADAPTER) {
            revert MarketErrors.Market__TooManyMarketsPerAdapter(params.oracleAdapter, siblings.length);
        }
        siblings.push(id);

        _params[id] = params;
        _market[id].lastUpdate = uint128(block.timestamp);
        // casting to 'uint128' is safe because R5 bounded the incentive to at most
        // MAX_LIF_ABSOLUTE (1.15e18) a few lines above, ~20 orders below type(uint128).max.
        // forge-lint: disable-next-line(unsafe-typecast)
        _market[id].liquidationIncentiveFactor = uint128(liquidationIncentiveFactor);
        // Starts unbounded; governance can only ever lower it.
        _hardCeiling[id] = type(uint128).max;

        emit MarketCreated(id, params, liquidationIncentiveFactor);
    }

    /// @dev R5, derived rather than chosen. At the LLTV boundary a liquidation seizes
    ///      `LIF * lltv` of the collateral. The route may be wrong by `deviationCombined`
    ///      without reverting, so for the seizure never to exceed the real collateral even at
    ///      that error: `LIF * lltv <= 1 - deviationCombined`.
    function _maxIncentive(uint256 deviationCombined, uint256 lltv) internal pure returns (uint256) {
        if (deviationCombined >= WAD) {
            revert MarketErrors.Market__R5_NoViableIncentive(deviationCombined, lltv);
        }
        uint256 derived = (WAD - deviationCombined).mulDivDown(WAD, lltv);
        // Below 1.0 a liquidator would receive less than they repay, so nobody would ever
        // liquidate. A market with no viable liquidation is not conservative; it is a market
        // with guaranteed bad debt.
        if (derived <= WAD) revert MarketErrors.Market__R5_NoViableIncentive(deviationCombined, lltv);
        return derived;
    }

    function _validateRoute(ICotejoOracleAdapter adapter, bytes32 asset, address expectedToken)
        internal
        view
    {
        IPriceRouter priceRouter = IPriceRouter(adapter.router());

        // R6 first: without proving the route describes the token this market custodies, every
        // other check validates a feed that might belong to something else entirely.
        address registered = priceRouter.tokenForAsset(asset);
        if (registered == address(0) || registered != expectedToken) {
            revert MarketErrors.Market__R6_AssetTokenMismatch(asset, registered, expectedToken);
        }

        IPriceRouter.Route memory route = priceRouter.getRoute(asset);

        // R1
        if (route.minSources < MIN_ROUTE_QUORUM) {
            revert MarketErrors.Market__R1_InsufficientRouteQuorum(asset, route.minSources, MIN_ROUTE_QUORUM);
        }

        // R7
        uint256 required = uint256(route.minSources) + ROUTE_REDUNDANCY;
        if (route.sources.length < required) {
            revert MarketErrors.Market__R7_InsufficientRedundancy(asset, route.sources.length, required);
        }

        // R2
        uint256 distinct = _countDistinctGroups(asset, route);
        if (distinct < MIN_DISTINCT_GROUPS) {
            revert MarketErrors.Market__R2_ConcentratedOracle(asset, distinct, MIN_DISTINCT_GROUPS);
        }
    }

    function _countDistinctGroups(bytes32 asset, IPriceRouter.Route memory route)
        internal
        view
        returns (uint256 distinct)
    {
        uint256 n = route.sources.length;
        bytes32[] memory seen = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            bytes32 group = IPriceSource(route.sources[i]).operatorGroupOf(asset);
            bool dup;
            for (uint256 j; j < distinct; ++j) {
                if (seen[j] == group) {
                    dup = true;
                    break;
                }
            }
            if (!dup) {
                seen[distinct] = group;
                unchecked {
                    ++distinct;
                }
            }
        }
    }

    // --------------------------------------------------------------------------------
    // Supply side — never needs a price
    // --------------------------------------------------------------------------------

    /// @inheritdoc ICotejoMarket
    function supply(MarketParams calldata params, uint256 assets, uint256 shares, address onBehalf)
        external
        override
        nonReentrant
        returns (uint256, uint256)
    {
        Id id = _id(params);
        _requireCreated(id);
        _requireExactlyOne(assets, shares);
        if (onBehalf == address(0)) revert MarketErrors.Market__InvalidParameter();

        _accrueInterest(id, params);
        Market storage m = _market[id];

        if (assets > 0) {
            shares = assets.toSharesDown(m.totalSupplyAssets, m.totalSupplyShares);
        } else {
            assets = shares.toAssetsUp(m.totalSupplyAssets, m.totalSupplyShares);
        }

        _position[id][onBehalf].supplyShares += shares;
        m.totalSupplyShares = _toUint128(uint256(m.totalSupplyShares) + shares);
        m.totalSupplyAssets = _toUint128(uint256(m.totalSupplyAssets) + assets);

        _pullExact(params.loanToken, msg.sender, assets);
        _touchDepthAnchor(params.oracleAdapter);

        emit Supply(id, onBehalf, assets, shares);
        return (assets, shares);
    }

    /// @inheritdoc ICotejoMarket
    /// @dev Blocked while the oracle is degraded. Allowing withdrawals then would create a
    ///      first-mover advantage: informed suppliers leave while the price is untrustworthy,
    ///      and any bad debt recognised afterwards falls entirely on whoever stayed. M3's
    ///      socialisation is only fair if nobody can run ahead of it.
    function withdraw(
        MarketParams calldata params,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external override nonReentrant returns (uint256, uint256) {
        Id id = _id(params);
        _requireCreated(id);
        _requireExactlyOne(assets, shares);
        if (receiver == address(0)) revert MarketErrors.Market__InvalidParameter();
        _requireOracleHealthy(id, params);

        _accrueInterest(id, params);
        Market storage m = _market[id];

        if (assets > 0) {
            shares = assets.toSharesUp(m.totalSupplyAssets, m.totalSupplyShares);
        } else {
            assets = shares.toAssetsDown(m.totalSupplyAssets, m.totalSupplyShares);
        }

        _position[id][onBehalf].supplyShares -= shares;
        m.totalSupplyShares = _toUint128(uint256(m.totalSupplyShares) - shares);
        m.totalSupplyAssets = _toUint128(uint256(m.totalSupplyAssets) - assets);

        // The guard has to precede the subtraction, or an over-withdrawal panics with 0x11 and
        // the typed error below is unreachable.
        if (uint256(m.totalSupplyAssets) < uint256(m.totalBorrowAssets)) {
            revert MarketErrors.Market__InsufficientLiquidity(id, assets, 0);
        }

        IERC20(params.loanToken).safeTransfer(receiver, assets);

        emit Withdraw(id, onBehalf, receiver, assets, shares);
        return (assets, shares);
    }

    // --------------------------------------------------------------------------------
    // Collateral
    // --------------------------------------------------------------------------------

    /// @inheritdoc ICotejoMarket
    function supplyCollateral(MarketParams calldata params, uint256 assets, address onBehalf)
        external
        override
        nonReentrant
    {
        Id id = _id(params);
        _requireCreated(id);
        if (assets == 0) revert MarketErrors.Market__ZeroAssets();
        if (onBehalf == address(0)) revert MarketErrors.Market__InvalidParameter();

        _position[id][onBehalf].collateral = _toUint128(uint256(_position[id][onBehalf].collateral) + assets);

        _pullExact(params.collateralToken, msg.sender, assets);
        emit SupplyCollateral(id, onBehalf, assets);
    }

    /// @inheritdoc ICotejoMarket
    /// @dev While the oracle is degraded this is allowed only for a position carrying no debt,
    ///      because with no debt there is no solvency check to perform.
    function withdrawCollateral(
        MarketParams calldata params,
        uint256 assets,
        address onBehalf,
        address receiver
    ) external override nonReentrant {
        Id id = _id(params);
        _requireCreated(id);
        if (assets == 0) revert MarketErrors.Market__ZeroAssets();
        if (receiver == address(0)) revert MarketErrors.Market__InvalidParameter();

        _accrueInterest(id, params);

        Position storage pos = _position[id][onBehalf];
        pos.collateral = _toUint128(uint256(pos.collateral) - assets);

        if (pos.borrowShares == 0) {
            IERC20(params.collateralToken).safeTransfer(receiver, assets);
            emit WithdrawCollateral(id, onBehalf, receiver, assets);
            return;
        }

        (bool ok, uint256 price, bytes memory err) = _observeOracle(params, true);
        if (!ok) {
            // Debt outstanding and no trustworthy price: solvency is unknowable, so the
            // collateral stays.
            revert MarketErrors.Market__OracleDegraded(id, err);
        }
        if (!_isHealthy(id, params, onBehalf, price)) {
            revert MarketErrors.Market__InsufficientCollateral(id, onBehalf);
        }

        IERC20(params.collateralToken).safeTransfer(receiver, assets);
        emit WithdrawCollateral(id, onBehalf, receiver, assets);
    }

    // --------------------------------------------------------------------------------
    // Borrow side
    // --------------------------------------------------------------------------------

    /// @inheritdoc ICotejoMarket
    function borrow(
        MarketParams calldata params,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external override nonReentrant returns (uint256, uint256) {
        Id id = _id(params);
        _requireCreated(id);
        _requireExactlyOne(assets, shares);
        if (receiver == address(0)) revert MarketErrors.Market__InvalidParameter();

        // A3. The band is enforced here and in `withdrawCollateral` — the two actions that
        // increase exposure — and nowhere else. Never on `liquidate`.
        (bool ok, uint256 price, bytes memory err) = _observeOracle(params, true);
        if (!ok) revert MarketErrors.Market__OracleDegraded(id, err);

        _accrueInterest(id, params);
        Market storage m = _market[id];

        if (assets > 0) {
            shares = assets.toSharesUp(m.totalBorrowAssets, m.totalBorrowShares);
        } else {
            assets = shares.toAssetsDown(m.totalBorrowAssets, m.totalBorrowShares);
        }

        _position[id][onBehalf].borrowShares =
            _toUint128(uint256(_position[id][onBehalf].borrowShares) + shares);
        m.totalBorrowShares = _toUint128(uint256(m.totalBorrowShares) + shares);
        m.totalBorrowAssets = _toUint128(uint256(m.totalBorrowAssets) + assets);

        if (!_isHealthy(id, params, onBehalf, price)) {
            revert MarketErrors.Market__InsufficientCollateral(id, onBehalf);
        }
        if (m.totalBorrowAssets > m.totalSupplyAssets) {
            revert MarketErrors.Market__InsufficientLiquidity(
                id, assets, uint256(m.totalSupplyAssets) - uint256(m.totalBorrowAssets - assets)
            );
        }

        // The depth cap, anchored and clamped. Checked last so the error a caller sees is the
        // binding one rather than whichever check happened to run first.
        //
        // F2. Measured across every market sharing this adapter, not just this one.
        _enforceCeilings(id, params, m.totalBorrowAssets);

        IERC20(params.loanToken).safeTransfer(receiver, assets);

        emit Borrow(id, onBehalf, receiver, assets, shares);
        return (assets, shares);
    }

    /// @inheritdoc ICotejoMarket
    /// @dev Always available, degraded or not. Reducing debt cannot harm anyone, and a
    ///      borrower who wants out must never be trapped by an oracle outage.
    function repay(MarketParams calldata params, uint256 assets, uint256 shares, address onBehalf)
        external
        override
        nonReentrant
        returns (uint256, uint256)
    {
        Id id = _id(params);
        _requireCreated(id);
        _requireExactlyOne(assets, shares);

        _accrueInterest(id, params);
        Market storage m = _market[id];

        if (assets > 0) {
            shares = assets.toSharesDown(m.totalBorrowAssets, m.totalBorrowShares);
        } else {
            assets = shares.toAssetsUp(m.totalBorrowAssets, m.totalBorrowShares);
        }

        _position[id][onBehalf].borrowShares =
            _toUint128(uint256(_position[id][onBehalf].borrowShares) - shares);
        m.totalBorrowShares = _toUint128(uint256(m.totalBorrowShares) - shares);
        m.totalBorrowAssets = _toUint128(MathLib.zeroFloorSub(m.totalBorrowAssets, assets));

        _pullExact(params.loanToken, msg.sender, assets);
        _touchDepthAnchor(params.oracleAdapter);
        _observeOracle(params, false);

        emit Repay(id, onBehalf, assets, shares);
        return (assets, shares);
    }

    // --------------------------------------------------------------------------------
    // Liquidation
    // --------------------------------------------------------------------------------

    /// @inheritdoc ICotejoMarket
    /// @dev Blocked whenever the oracle refuses. This is the decision the whole design turns
    ///      on: liquidating against a manipulated price is the extraction mechanism itself,
    ///      not a defence against it.
    function liquidate(
        MarketParams calldata params,
        address borrower,
        uint256 seizedCollateral,
        uint256 repaidShares
    ) external override nonReentrant returns (uint256, uint256) {
        Id id = _id(params);
        _requireCreated(id);
        _requireExactlyOne(seizedCollateral, repaidShares);

        // Observed, but deliberately never band-gated: solvency control must not be
        // suspended because a price moved fast. That exemption is what makes A3 safe.
        (bool ok, uint256 price, bytes memory err) = _observeOracle(params, false);
        if (!ok) revert MarketErrors.Market__OracleDegraded(id, err);

        _accrueInterest(id, params);

        if (_isHealthy(id, params, borrower, price)) {
            revert MarketErrors.Market__HealthyPosition(id, borrower);
        }

        Liq memory v = _sizeLiquidation(id, params, borrower, price, seizedCollateral, repaidShares);
        _applyLiquidation(id, params.oracleAdapter, borrower, v);

        _pullExact(params.loanToken, msg.sender, v.repaidAssets);
        IERC20(params.collateralToken).safeTransfer(msg.sender, v.seizedCollateral);

        emit Liquidate(
            id, msg.sender, borrower, v.repaidAssets, v.repaidShares, v.seizedCollateral, v.badDebt
        );
        return (v.seizedCollateral, v.repaidAssets);
    }

    /// @dev One liquidation's worth of arithmetic. Passed around as a memory struct rather
    ///      than a dozen locals, which is what keeps `liquidate` inside the EVM's reachable
    ///      stack depth without compiling the project through the IR pipeline.
    struct Liq {
        uint256 repaidAssets;
        uint256 repaidShares;
        uint256 seizedCollateral;
        uint256 badDebt;
    }

    /// @dev Rounding throughout favours the market: the liquidator repays at least what the
    ///      collateral they take is worth, never less.
    function _sizeLiquidation(
        Id id,
        MarketParams memory params,
        address borrower,
        uint256 price,
        uint256 seizedCollateral,
        uint256 repaidShares
    ) internal view returns (Liq memory v) {
        Market memory m = _market[id];
        Position memory pos = _position[id][borrower];
        uint256 lif = m.liquidationIncentiveFactor;
        uint256 scale = ICotejoOracleAdapter(params.oracleAdapter).PRICE_SCALE();

        if (seizedCollateral > 0) {
            v.seizedCollateral = seizedCollateral;
            v.repaidAssets = seizedCollateral.mulDivUp(price, scale).wDivUp(lif);
            v.repaidShares = v.repaidAssets.toSharesDown(m.totalBorrowAssets, m.totalBorrowShares);
        } else {
            v.repaidShares = repaidShares;
            v.repaidAssets = repaidShares.toAssetsUp(m.totalBorrowAssets, m.totalBorrowShares);
            v.seizedCollateral = v.repaidAssets.wMulDown(lif).mulDivDown(scale, price);
        }

        uint256 debtAssets = uint256(pos.borrowShares).toAssetsUp(m.totalBorrowAssets, m.totalBorrowShares);

        // A4. Once the debt exceeds what the collateral is worth, the partial-liquidation cap
        // protects nothing — the borrower is already insolvent — and it actively harms the
        // market by forcing a liquidator to pay gas repeatedly against a shrinking, still
        // underwater target. Allow a single close in that case.
        uint256 collateralValue = uint256(pos.collateral).mulDivDown(price, scale);
        uint256 closeFactor = debtAssets > collateralValue ? WAD : CLOSE_FACTOR;
        uint256 maxRepayable = debtAssets.wMulDown(closeFactor);
        if (v.repaidAssets > maxRepayable) {
            revert MarketErrors.Market__CloseFactorExceeded(v.repaidAssets, maxRepayable);
        }
        if (v.seizedCollateral > pos.collateral) v.seizedCollateral = pos.collateral;
        if (v.repaidShares > pos.borrowShares) v.repaidShares = pos.borrowShares;
    }

    /// @dev Writes the result down, and recognises bad debt in the same transaction.
    function _applyLiquidation(Id id, address adapter, address borrower, Liq memory v) internal {
        Market storage m = _market[id];
        Position storage pos = _position[id][borrower];

        pos.borrowShares = _toUint128(uint256(pos.borrowShares) - v.repaidShares);
        pos.collateral = _toUint128(uint256(pos.collateral) - v.seizedCollateral);
        m.totalBorrowShares = _toUint128(uint256(m.totalBorrowShares) - v.repaidShares);
        m.totalBorrowAssets = _toUint128(MathLib.zeroFloorSub(m.totalBorrowAssets, v.repaidAssets));

        // M3. Recognised on every liquidation, partial or total, and whenever a position ends
        // with no collateral and outstanding debt. Recognising late would let suppliers exit
        // around a loss that already exists.
        if (pos.collateral == 0 && pos.borrowShares > 0) {
            v.badDebt = uint256(pos.borrowShares).toAssetsUp(m.totalBorrowAssets, m.totalBorrowShares);
            m.totalBorrowShares = _toUint128(uint256(m.totalBorrowShares) - pos.borrowShares);
            m.totalBorrowAssets = _toUint128(MathLib.zeroFloorSub(m.totalBorrowAssets, v.badDebt));
            // Socialised among this market's suppliers only. No other market is touched.
            m.totalSupplyAssets = _toUint128(MathLib.zeroFloorSub(m.totalSupplyAssets, v.badDebt));
            pos.borrowShares = 0;

            // A1.2. Bad debt is on-chain proof that the depth the reporters claimed was not
            // there: a liquidator could not clear the position against the book that was
            // supposed to exist. Halve the anchor so the ceiling reflects what actually
            // happened rather than what was asserted. This is the only check in the system on
            // a reporter's claim that uses evidence the reporters do not produce.
            DepthAnchor storage anchor = _depthAnchor[adapter];
            if (anchor.timestamp != 0) {
                uint256 cut = uint256(anchor.depthUsd) * BAD_DEBT_DEPTH_HAIRCUT_BPS / 10_000;
                anchor.depthUsd = _toUint128(cut);
                anchor.timestamp = uint128(block.timestamp);
                emit DepthAnchorUpdated(adapter, cut);
            }
        }
    }

    /// @inheritdoc ICotejoMarket
    /// @dev The escape from the griefing vector that blocking liquidation creates. An
    ///      underwater borrower benefits from degradation, and R7 makes causing it expensive
    ///      without making it impossible — so after a long enough outage there has to be a way
    ///      to wind a position down that does not reopen the extraction path.
    ///
    ///      The property that makes it safe is narrow and worth stating plainly: **no live
    ///      price appears anywhere in the seizure arithmetic.** The liquidator repays a
    ///      fraction of the debt and receives that same fraction of the collateral. At zero
    ///      premium that leaves the collateralisation ratio exactly where it was.
    ///
    ///      Note what it therefore does *not* do: it does not restore health. Pro-rata
    ///      shrinking of an underwater position leaves it underwater. This is a wind-down
    ///      valve, not a solvency repair, and pretending otherwise would be dishonest.
    ///
    ///      One mechanism covers two threats. A guardian pause and a reporter outage are
    ///      indistinguishable here — both make `price()` revert, both start the same clock —
    ///      so this is also the answer to governance freezing a market by pausing an asset.
    function liquidateDegraded(MarketParams calldata params, address borrower, uint256 repaidShares)
        external
        override
        nonReentrant
        returns (uint256, uint256)
    {
        Id id = _id(params);
        _requireCreated(id);
        if (repaidShares == 0) revert MarketErrors.Market__ZeroShares();

        // Refresh the clock first: an adapter that has recovered must not be wound down.
        _observeOracle(params, false);
        _requireDegradedLongEnough(params.oracleAdapter);

        _accrueInterest(id, params);
        _requireUnhealthyAtAnchor(id, params, borrower);

        Wind memory w = _sizeDegraded(id, borrower, repaidShares);
        _applyDegraded(id, borrower, repaidShares, w);

        _pullExact(params.loanToken, msg.sender, w.repaidAssets);
        IERC20(params.collateralToken).safeTransfer(msg.sender, w.seized);

        emit LiquidateDegraded(id, msg.sender, borrower, w.repaidAssets, repaidShares, w.seized, w.premiumBps);
        return (w.seized, w.repaidAssets);
    }

    /// @dev One wind-down's arithmetic, as a memory struct to keep the caller inside the
    ///      EVM's reachable stack depth.
    struct Wind {
        uint256 seized;
        uint256 repaidAssets;
        uint256 premiumBps;
    }

    function _requireDegradedLongEnough(address adapter) internal view {
        uint64 since = _degradedSince[adapter];
        if (since == 0 || block.timestamp - since < DEGRADED_GRACE) {
            revert MarketErrors.Market__NotDegradedLongEnough(adapter, since, DEGRADED_GRACE);
        }
    }

    /// @dev Eligibility only. The anchor decides *who* may be wound down; nothing below this
    ///      line consults it again, and no token amount is ever derived from it (INV-7').
    function _requireUnhealthyAtAnchor(Id id, MarketParams memory params, address borrower) internal view {
        PriceAnchor memory anchor = _priceAnchor[params.oracleAdapter];
        if (anchor.at == 0) revert MarketErrors.Market__NoPriceAnchor(params.oracleAdapter);
        if (_isHealthy(id, params, borrower, anchor.price)) {
            revert MarketErrors.Market__HealthyAtAnchor(id, borrower);
        }
    }

    function _applyDegraded(Id id, address borrower, uint256 repaidShares, Wind memory w) internal {
        Position storage pos = _position[id][borrower];
        Market storage m = _market[id];
        pos.borrowShares = _toUint128(uint256(pos.borrowShares) - repaidShares);
        pos.collateral = _toUint128(uint256(pos.collateral) - w.seized);
        m.totalBorrowShares = _toUint128(uint256(m.totalBorrowShares) - repaidShares);
        m.totalBorrowAssets = _toUint128(MathLib.zeroFloorSub(m.totalBorrowAssets, w.repaidAssets));
    }

    /// @dev Pro-rata, plus a premium that grows with the length of the outage. Every input is
    ///      a share count, a collateral balance, or elapsed time — no price of any kind. That
    ///      is the property `invariant_degradedSeizureIsPriceIndependent` exists to pin.
    function _sizeDegraded(Id id, address borrower, uint256 repaidShares)
        internal
        view
        returns (Wind memory w)
    {
        Position memory pos = _position[id][borrower];
        Market memory m = _market[id];

        uint256 maxShares = uint256(pos.borrowShares).wMulDown(CLOSE_FACTOR);
        if (repaidShares > maxShares) {
            revert MarketErrors.Market__CloseFactorExceeded(repaidShares, maxShares);
        }

        uint256 rampedFor =
            block.timestamp - (uint256(_degradedSince[_params[id].oracleAdapter]) + DEGRADED_GRACE);
        w.premiumBps = MathLib.min(
            rampedFor * DEGRADED_PREMIUM_MAX_BPS / DEGRADED_PREMIUM_RAMP, DEGRADED_PREMIUM_MAX_BPS
        );

        uint256 proRata = uint256(pos.collateral) * repaidShares / uint256(pos.borrowShares);
        w.seized = proRata + proRata * w.premiumBps / 10_000;
        if (w.seized > pos.collateral) w.seized = pos.collateral;

        w.repaidAssets = repaidShares.toAssetsUp(m.totalBorrowAssets, m.totalBorrowShares);
    }

    // --------------------------------------------------------------------------------
    // Interest
    // --------------------------------------------------------------------------------

    /// @inheritdoc ICotejoMarket
    function accrueInterest(MarketParams calldata params) external override nonReentrant {
        Id id = _id(params);
        _requireCreated(id);
        _accrueInterest(id, params);
    }

    /// @dev Keeps accruing during degraded mode. Freezing the clock would reward whoever
    ///      caused the degradation; R7 is the mitigation, not stopping time.
    function _accrueInterest(Id id, MarketParams memory params) internal {
        Market storage m = _market[id];
        uint256 elapsed = block.timestamp - m.lastUpdate;
        if (elapsed == 0) return;

        if (m.totalBorrowAssets > 0) {
            // A5.1. `borrowRate` is non-view and sits on every state-changing path, so an IRM
            // that reverts — or that is a proxy later repointed at one, or that simply burns
            // every drop of forwarded gas — would freeze this market permanently, `repay` and
            // `liquidate` included, with funds inside. `params.irm` is baked into the `Id`, so
            // de-whitelisting cannot rescue a market that already exists: R4 is a
            // creation-time check only.
            //
            // The gas cap is the same defence `PriceRouter._readSource` applies to sources and
            // for the same reason: without it the 63/64 rule leaves the caller unable to
            // finish, and `try/catch` becomes the denial vector instead of the protection.
            // A failed model means 0% interest until governance acts, which is recoverable;
            // a frozen market is not.
            uint256 rate;
            try IIrm(params.irm).borrowRate{gas: IRM_GAS_LIMIT}(params, m) returns (uint256 r) {
                rate = r > MAX_BORROW_RATE ? MAX_BORROW_RATE : r; // M5
            } catch {
                rate = 0;
                emit IrmCallFailed(id, params.irm);
            }
            uint256 interest = uint256(m.totalBorrowAssets).wMulDown(rate.wTaylorCompounded(elapsed));
            m.totalBorrowAssets = _toUint128(uint256(m.totalBorrowAssets) + interest);
            m.totalSupplyAssets = _toUint128(uint256(m.totalSupplyAssets) + interest);
            emit AccrueInterest(id, rate, interest);
        }

        m.lastUpdate = uint128(block.timestamp);
    }

    // --------------------------------------------------------------------------------
    // Depth cap (M1)
    // --------------------------------------------------------------------------------

    /// @dev Both debt ceilings, refreshed and enforced. Split out of `borrow` to keep it
    ///      inside the EVM's reachable stack depth.
    ///
    ///      The two bind on different things and neither subsumes the other. The shared
    ///      ceiling asks "could liquidators unwind this much of this order book", and applies
    ///      across every market on the adapter, because the book does not care how many `Id`s
    ///      were minted against it. The ratchet asks "has governance decided this particular
    ///      market should shrink", and applies to one market alone.
    function _enforceCeilings(Id id, MarketParams memory params, uint256 marketBorrow) internal {
        uint256 cap = _refreshAndCap(params);
        uint256 adapterDebt = _adapterTotalBorrow(params.oracleAdapter);
        if (adapterDebt > cap) {
            revert MarketErrors.Market__DepthCapExceeded(id, adapterDebt, cap);
        }

        uint256 ceiling = _hardCeiling[id];
        if (marketBorrow > ceiling) {
            revert MarketErrors.Market__DebtCeilingExceeded(id, marketBorrow, ceiling);
        }
    }

    /// @notice Advances an adapter's depth anchor without borrowing. Permissionless.
    /// @dev The anchor used to move only inside `borrow`, which is what let the growth clamp
    ///      evaporate over a quiet period. Anyone may now keep it current, and keeping it
    ///      current is in the interest of anyone who wants to borrow.
    ///
    ///      A caller can also ratchet the anchor *down* by poking at a genuinely thin moment.
    ///      That is the fail-closed direction, it costs them gas, and it inconveniences
    ///      borrowers rather than endangering suppliers — an acceptable trade for closing a
    ///      hole that removed the clamp entirely.
    function pokeDepthAnchor(MarketParams calldata params) external override nonReentrant {
        _requireCreated(_id(params));
        _touchDepthAnchor(params.oracleAdapter);
    }

    /// @dev Non-reverting anchor refresh for paths that must work while degraded.
    function _touchDepthAnchor(address adapter) internal {
        try ICotejoOracleAdapter(adapter).bindingDepthUsd() returns (uint256 reported) {
            uint256 clamped = _clampDepth(adapter, reported);
            _depthAnchor[adapter] =
                DepthAnchor({depthUsd: _toUint128(clamped), timestamp: uint128(block.timestamp)});
            emit DepthAnchorUpdated(adapter, clamped);
        } catch {
            // Degraded. Leave the anchor where it is rather than letting an outage reset it.
        }
    }

    /// @dev Refreshes the anchor and returns the adapter's ceiling. Used by `borrow`, which
    ///      must revert rather than proceed on an unreadable depth.
    function _refreshAndCap(MarketParams memory params) internal returns (uint256) {
        address adapter = params.oracleAdapter;
        uint256 reported = ICotejoOracleAdapter(adapter).bindingDepthUsd();
        uint256 clamped = _clampDepth(adapter, reported);

        _depthAnchor[adapter] =
            DepthAnchor({depthUsd: _toUint128(clamped), timestamp: uint128(block.timestamp)});
        emit DepthAnchorUpdated(adapter, clamped);

        return _capFromDepth(params, clamped);
    }

    /// @dev Caps growth rather than rejecting it. Rejecting outright would block borrowing on
    ///      any upward spike, including an honest recovery after a quiet market. Clamping
    ///      removes the benefit of inflating depth immediately before a large borrow while
    ///      still letting the figure climb at a bounded rate. Falls are not clamped at all:
    ///      a drop in liquidity takes effect at once, which is the conservative direction.
    ///
    ///      `elapsed` is capped at `DEPTH_CLAMP_MAX_ELAPSED`. Without that cap the allowance
    ///      accumulates without bound while nobody borrows, and the clamp stops existing.
    function _clampDepth(address adapter, uint256 reported) internal view returns (uint256) {
        DepthAnchor memory anchor = _depthAnchor[adapter];
        if (anchor.timestamp == 0) return reported;
        if (reported <= anchor.depthUsd) return reported;

        uint256 elapsed = MathLib.min(block.timestamp - anchor.timestamp, DEPTH_CLAMP_MAX_ELAPSED);
        uint256 allowedGrowth =
            uint256(anchor.depthUsd) * DEPTH_GROWTH_BPS_PER_HOUR * elapsed / (10_000 * 1 hours);
        uint256 ceiling = uint256(anchor.depthUsd) + allowedGrowth;
        return reported > ceiling ? ceiling : reported;
    }

    /// @dev Converts an observed depth into a debt ceiling in loan-token units, then applies
    ///      the report-independent hard ceiling (A1.1).
    function _capFromDepth(MarketParams memory params, uint256 depthUsd) internal view returns (uint256) {
        ICotejoOracleAdapter adapter = ICotejoOracleAdapter(params.oracleAdapter);
        uint256 loanPrice = adapter.loanPriceUsd();
        if (loanPrice == 0) revert MarketErrors.Market__DepthUnavailable(_id(params));

        // A1.1. Whichever is smaller: what the reporters claim supports, or what was decided
        // before deployment without consulting them at all.
        uint256 usdCap = MathLib.min(depthUsd * DEPTH_MULTIPLIER_BPS / 10_000, MAX_ADAPTER_DEBT_USD);

        // usdCap is whole USD; loanPrice is USD per whole loan token in WAD.
        return usdCap * WAD * (10 ** adapter.loanTokenDecimals()) / loanPrice;
    }

    /// @dev F2. Total debt across every market sharing an adapter.
    ///      `createMarket` is permissionless and `lltv` is part of the `Id`, so without this
    ///      anyone could mint N markets over one adapter and hand each a full ceiling against
    ///      the same order book — defeating the depth cap by arithmetic rather than by
    ///      touching the oracle. Summed live rather than tracked incrementally so accrued
    ///      interest is included and no running total can drift.
    ///
    ///      Both amounts are in the same loan token: R6 pins every market on an adapter to the
    ///      token its `loanAsset` resolves to, so no conversion is involved.
    function _adapterTotalBorrow(address adapter) internal view returns (uint256 total) {
        Id[] storage ids = _adapterMarkets[adapter];
        uint256 n = ids.length;
        for (uint256 i; i < n; ++i) {
            total += _market[ids[i]].totalBorrowAssets;
        }
    }

    /// @inheritdoc ICotejoMarket
    function maxTotalBorrow(MarketParams calldata params) external view override returns (uint256) {
        uint256 reported = ICotejoOracleAdapter(params.oracleAdapter).bindingDepthUsd();
        return _capFromDepth(params, _clampDepth(params.oracleAdapter, reported));
    }

    /// @inheritdoc ICotejoMarket
    function adapterTotalBorrow(address adapter) external view override returns (uint256) {
        return _adapterTotalBorrow(adapter);
    }

    /// @inheritdoc ICotejoMarket
    function hardCeilingOf(Id id) external view override returns (uint256) {
        return _hardCeiling[id];
    }

    // --------------------------------------------------------------------------------
    // Oracle observation, price band (A3), degradation clock (A2)
    // --------------------------------------------------------------------------------

    /// @notice Records oracle availability and advances the price anchor. Permissionless.
    /// @dev The degradation clock has to be driven by *someone*. Making it permissionless
    ///      means a liquidator who needs the wind-down path can start the clock themselves
    ///      rather than waiting for organic traffic.
    function pokeOracleState(MarketParams calldata params) external override nonReentrant {
        _requireCreated(_id(params));
        _observeOracle(params, false);
    }

    /// @dev Single entry point for everything the market learns from an oracle read.
    ///
    ///      `enforceBand` is true only on `borrow` and `withdrawCollateral` — the two actions
    ///      that increase exposure. The check runs *before* the anchor advances, or the anchor
    ///      would absorb the very move it is meant to catch.
    function _observeOracle(MarketParams memory params, bool enforceBand)
        internal
        returns (bool ok, uint256 price, bytes memory err)
    {
        address adapter = params.oracleAdapter;
        (ok, price, err) = _tryPrice(params);

        if (!ok) {
            if (_degradedSince[adapter] == 0) {
                _degradedSince[adapter] = uint64(block.timestamp);
                emit OracleDegraded(adapter, block.timestamp);
            }
            return (ok, price, err);
        }

        if (_degradedSince[adapter] != 0) {
            _degradedSince[adapter] = 0;
            emit OracleRecovered(adapter);
        }

        if (enforceBand) _requireWithinBand(adapter, price);
        _anchorPrice(adapter, price);
    }

    /// @dev The band widens with time since the anchor, so a market that has been quiet does
    ///      not trip on the first honest move, while a burst inside one block does.
    function _band(uint64 anchoredAt) internal view returns (uint256) {
        uint256 elapsed = block.timestamp - anchoredAt;
        return
            MathLib.min(
                PRICE_BAND_FLOOR_BPS + PRICE_BAND_BPS_PER_HOUR * elapsed / 1 hours, MAX_PRICE_BAND_BPS
            );
    }

    /// @dev A3. Upward only, and never applied to `liquidate`.
    ///
    ///      Upward: the collateral/loan price climbing abnormally fast is the over-borrowing
    ///      direction — the Tectonic direction — and pausing new debt there is cheap.
    ///
    ///      Downward: a breaker on a falling price would trip during a genuine crash, degrade
    ///      the market, and freeze liquidations exactly when they matter most. That does not
    ///      prevent bad debt; it manufactures it. The deflation direction is therefore left
    ///      unguarded here and bounded by `MAX_ADAPTER_DEBT_USD` instead.
    function _requireWithinBand(address adapter, uint256 observed) internal view {
        PriceAnchor memory a = _priceAnchor[adapter];
        if (a.at == 0) return; // nothing to compare against yet

        uint256 ceiling = uint256(a.price) + uint256(a.price) * _band(a.at) / 10_000;
        if (observed > ceiling) {
            revert MarketErrors.Market__PriceBandExceeded(adapter, observed, ceiling);
        }
    }

    /// @dev Ratchets the anchor toward the observed price, never faster than the band.
    ///
    ///      The clamp is the half a reviewer will skip and the half that makes the breaker
    ///      work. Without it the breaker falls in one block: inflate the price, call any
    ///      permissionless mutator to anchor the lie, then borrow against it freely.
    function _anchorPrice(address adapter, uint256 observed) internal {
        PriceAnchor memory a = _priceAnchor[adapter];
        if (a.at == 0) {
            _priceAnchor[adapter] = PriceAnchor(_toUint128(observed), uint64(block.timestamp));
            return;
        }

        uint256 band = _band(a.at);
        uint256 span = uint256(a.price) * band / 10_000;
        uint256 next = observed;
        if (observed > uint256(a.price) + span) next = uint256(a.price) + span;
        else if (observed + span < uint256(a.price)) next = uint256(a.price) - span;

        _priceAnchor[adapter] = PriceAnchor(_toUint128(next), uint64(block.timestamp));
    }

    /// @inheritdoc ICotejoMarket
    function oracleAnchor(address adapter)
        external
        view
        override
        returns (uint256 anchoredPrice, uint64 anchoredAt, uint64 degradedSince)
    {
        PriceAnchor memory a = _priceAnchor[adapter];
        return (a.price, a.at, _degradedSince[adapter]);
    }

    // --------------------------------------------------------------------------------
    // Oracle helpers
    // --------------------------------------------------------------------------------

    function _tryPrice(MarketParams memory params)
        internal
        view
        returns (bool ok, uint256 price, bytes memory err)
    {
        try ICotejoOracleAdapter(params.oracleAdapter).price() returns (uint256 p) {
            if (p == 0) return (false, 0, hex"");
            return (true, p, hex"");
        } catch (bytes memory reason) {
            return (false, 0, reason);
        }
    }

    function _requireOracleHealthy(Id id, MarketParams memory params) internal view {
        (bool ok,, bytes memory err) = _tryPrice(params);
        if (!ok) revert MarketErrors.Market__OracleDegraded(id, err);
    }

    /// @inheritdoc ICotejoMarket
    function isOracleHealthy(MarketParams calldata params)
        external
        view
        override
        returns (bool healthy, bytes memory oracleError)
    {
        (healthy,, oracleError) = _tryPrice(params);
    }

    function _isHealthy(Id id, MarketParams memory params, address user, uint256 price)
        internal
        view
        returns (bool)
    {
        Position memory pos = _position[id][user];
        if (pos.borrowShares == 0) return true;

        Market memory m = _market[id];
        uint256 scale = ICotejoOracleAdapter(params.oracleAdapter).PRICE_SCALE();

        uint256 collateralValue = uint256(pos.collateral).mulDivDown(price, scale);
        uint256 maxBorrow = collateralValue.wMulDown(params.lltv);
        uint256 borrowed = uint256(pos.borrowShares).toAssetsUp(m.totalBorrowAssets, m.totalBorrowShares);

        return borrowed <= maxBorrow;
    }

    /// @inheritdoc ICotejoMarket
    function isHealthy(MarketParams calldata params, address user) external view override returns (bool) {
        (bool ok, uint256 price,) = _tryPrice(params);
        if (!ok) return false;
        return _isHealthy(_id(params), params, user, price);
    }

    // --------------------------------------------------------------------------------
    // Token handling (M6)
    // --------------------------------------------------------------------------------

    /// @dev Verifies the balance actually moved by the amount claimed. Fee-on-transfer and
    ///      rebasing tokens fail here on first use instead of silently desynchronising the
    ///      accounting from the balance sheet.
    function _pullExact(address token, address from, uint256 amount) internal {
        if (amount == 0) return;
        uint256 before = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(from, address(this), amount);
        uint256 delta = IERC20(token).balanceOf(address(this)) - before;
        if (delta != amount) {
            revert MarketErrors.Market__UnexpectedBalanceDelta(token, amount, delta);
        }
    }

    // --------------------------------------------------------------------------------
    // Admin — the whitelist, and nothing else
    // --------------------------------------------------------------------------------

    /// @notice Adds or removes an interest rate model from the whitelist (R4).
    /// @dev The only administrative power in this contract. It cannot change a market's LLTV,
    ///      its oracle, its incentive, or its debt ceiling — none of those have setters at any
    ///      access level, because a market whose risk parameters can move under live positions
    ///      is the problem this design exists to avoid.
    /// @dev A5.3. Granting waits; revoking does not.
    ///
    ///      Be clear about how little this buys on its own. R4 is a creation-time check and
    ///      `irm` is baked into the `Id`, so revoking does **nothing** for markets that
    ///      already exist — the delay only narrows the window in which a compromised owner can
    ///      both whitelist a hostile model and get a market created against it. What actually
    ///      bounds the damage is the gas-capped `try/catch` and the reentrancy guard; this is
    ///      the third line, not the first.
    function proposeIrm(address irm) external onlyOwner {
        if (irm == address(0)) revert MarketErrors.Market__InvalidParameter();
        if (_irmWhitelist[irm]) revert MarketErrors.Market__InvalidParameter();
        if (_pendingIrm[irm] != 0) revert MarketErrors.Market__InvalidParameter();

        // casting to 'uint64' is safe because block.timestamp + 48h stays far below
        // type(uint64).max.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 eta = uint64(block.timestamp + IRM_TIMELOCK);
        _pendingIrm[irm] = eta;
        emit IrmProposed(irm, eta);
    }

    /// @inheritdoc ICotejoMarket
    function executeIrm(address irm) external override {
        uint64 eta = _pendingIrm[irm];
        if (eta == 0) revert MarketErrors.Market__InvalidParameter();
        if (block.timestamp < eta) {
            revert MarketErrors.Market__IrmTimelockNotElapsed(irm, eta, block.timestamp);
        }
        delete _pendingIrm[irm];
        _irmWhitelist[irm] = true;
        emit IrmWhitelisted(irm, true);
    }

    /// @inheritdoc ICotejoMarket
    /// @dev Immediate. Removing a capability can only ever restrict.
    function revokeIrm(address irm) external override onlyOwner {
        delete _pendingIrm[irm];
        _irmWhitelist[irm] = false;
        emit IrmWhitelisted(irm, false);
    }

    /// @inheritdoc ICotejoMarket
    function pendingIrm(address irm) external view override returns (uint64 eta) {
        return _pendingIrm[irm];
    }

    /// @inheritdoc ICotejoMarket
    /// @dev Monotonically decreasing, which is what makes it safe without a timelock. A
    ///      compromised owner can ratchet every market to zero; that blocks new borrowing and
    ///      leaves `liquidate` and `repay` untouched, because neither consults the ceiling. It
    ///      is a liveness loss, not a safety one — the same asymmetry the oracle layer already
    ///      relies on for guardian pause.
    ///
    ///      Note what this deliberately cannot do: it cannot raise a ceiling, and there is no
    ///      companion function that can. Raising one would be the lever an attacker wants.
    function ratchetDebtCeiling(Id id, uint128 newCeiling) external override onlyOwner {
        _requireCreated(id);
        uint256 current = _hardCeiling[id];
        if (newCeiling >= current) {
            revert MarketErrors.Market__CeilingNotDecreasing(id, current, newCeiling);
        }
        _hardCeiling[id] = newCeiling;
        emit DebtCeilingRatcheted(id, newCeiling);
    }

    // --------------------------------------------------------------------------------
    // Views and internals
    // --------------------------------------------------------------------------------

    function marketOf(Id id) external view override returns (Market memory) {
        return _market[id];
    }

    function positionOf(Id id, address user) external view override returns (Position memory) {
        return _position[id][user];
    }

    function paramsOf(Id id) external view override returns (MarketParams memory) {
        return _params[id];
    }

    function isIrmWhitelisted(address irm) external view override returns (bool) {
        return _irmWhitelist[irm];
    }

    function idOf(MarketParams calldata params) external pure returns (Id) {
        return _id(params);
    }

    function _id(MarketParams memory params) internal pure returns (Id) {
        return Id.wrap(keccak256(abi.encode(params)));
    }

    function _requireCreated(Id id) internal view {
        if (_market[id].lastUpdate == 0) revert MarketErrors.Market__NotCreated(id);
    }

    function _requireExactlyOne(uint256 a, uint256 b) internal pure {
        if ((a == 0) == (b == 0)) revert MarketErrors.Market__InconsistentInput();
    }

    function _toUint128(uint256 value) internal pure returns (uint128) {
        if (value > type(uint128).max) revert MarketErrors.Market__MaxUint128Overflow(value);
        // casting to 'uint128' is safe because the line above reverts on anything that would
        // truncate. This function *is* the checked cast.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(value);
    }
}
