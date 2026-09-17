// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IIrm} from "./interfaces/IIrm.sol";
import {Id, MarketParams, Market} from "./types/MarketTypes.sol";
import {MarketErrors} from "./libraries/MarketErrors.sol";
import {MathLib} from "./libraries/MathLib.sol";

/// @title AdaptiveCurveIrm
/// @notice Interest rate model whose curve slides to keep utilisation near a target.
///
/// @dev Two mechanisms stacked. The *curve* sets an instantaneous rate from how far
///      utilisation sits from target, steepening sharply above it. The *adaptation* moves the
///      curve's anchor — the rate charged exactly at target — slowly, so a market that stays
///      over-utilised gets progressively more expensive rather than merely spiking.
///
///      The adaptation is linear per second and clamped, where Morpho's original is
///      exponential. That is a deliberate simplification: exponentiation in fixed point is a
///      meaningful chunk of code to get right, and the clamped linear form is monotonic in the
///      same direction, bounded at both ends, and far easier to reason about. It adapts more
///      slowly during sustained extremes, which errs toward stability.
///
///      Whatever this returns, `CotejoMarket` clamps to `MAX_BORROW_RATE` (M5). This model
///      cannot make borrowing arbitrarily expensive even if its state were somehow corrupted.
///
///      **On the signed casts below.** The curve is inherently signed — utilisation sits above
///      or below target — so `_compute` converts between `uint256` and `int256` throughout.
///      The linter flags every one; each is bounded by construction and the argument is here
///      rather than repeated fifteen times:
///
///        - Every `int256(x)` on a `uint256` operates on a value bounded by `WAD` (an error
///          term or a curve constant) or by `MAX_RATE_AT_TARGET` (~6.3e10). Both are ~60
///          orders of magnitude below `type(int256).max`.
///        - `ADJUSTMENT_SPEED * elapsed` is the one product worth checking: at 1.5854e12 per
///          second it would need `elapsed` near 7e64 seconds to overflow `uint256`, and the
///          largest intermediate it feeds (`anchor * drift`) sits around 1e32 for a decade of
///          elapsed time.
///        - The two `uint256(int256)` conversions — `uint256(multiplier)` and the tail of
///          `_clampAnchor` — are each preceded by the branch that makes a negative value
///          impossible. Those are the only two where a wrap would be dangerous, and both are
///          guarded on the line above.
contract AdaptiveCurveIrm is IIrm {
    using MathLib for uint256;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    /// @notice Utilisation the curve is anchored at.
    uint256 public constant TARGET_UTILIZATION = 0.9e18;

    /// @notice Ratio between the rate at full utilisation and the rate at zero.
    uint256 public constant CURVE_STEEPNESS = 4e18;

    /// @notice How fast the anchor moves, per unit of error per second, in WAD.
    uint256 public constant ADJUSTMENT_SPEED = 1.5854e12;

    /// @notice 4% APR, expressed per second.
    uint256 public constant INITIAL_RATE_AT_TARGET = 0.04e18 / SECONDS_PER_YEAR;

    /// @notice 0.1% APR floor.
    uint256 public constant MIN_RATE_AT_TARGET = 0.001e18 / SECONDS_PER_YEAR;

    /// @notice 200% APR ceiling on the anchor itself.
    uint256 public constant MAX_RATE_AT_TARGET = 2e18 / SECONDS_PER_YEAR;

    /// @notice The only contract allowed to move this model's state.
    address public immutable MARKET;

    mapping(Id id => uint256 rate) private _rateAtTarget;

    event RateAtTargetUpdated(Id indexed id, uint256 rateAtTarget);

    constructor(address market_) {
        if (market_ == address(0)) revert MarketErrors.Market__InvalidParameter();
        MARKET = market_;
    }

    /// @inheritdoc IIrm
    function borrowRate(MarketParams calldata params, Market calldata market)
        external
        override
        returns (uint256)
    {
        if (msg.sender != MARKET) revert MarketErrors.Market__InvalidParameter();

        Id id = Id.wrap(keccak256(abi.encode(params)));
        (uint256 rate, uint256 newAnchor) = _compute(id, market);

        if (newAnchor != _rateAtTarget[id]) {
            _rateAtTarget[id] = newAnchor;
            emit RateAtTargetUpdated(id, newAnchor);
        }
        return rate;
    }

    /// @inheritdoc IIrm
    function borrowRateView(MarketParams calldata params, Market calldata market)
        external
        view
        override
        returns (uint256)
    {
        (uint256 rate,) = _compute(Id.wrap(keccak256(abi.encode(params))), market);
        return rate;
    }

    /// @notice The anchor rate currently in effect for a market.
    function rateAtTarget(Id id) external view returns (uint256) {
        uint256 stored = _rateAtTarget[id];
        return stored == 0 ? INITIAL_RATE_AT_TARGET : stored;
    }

    function _compute(Id id, Market memory market) internal view returns (uint256 rate, uint256 newAnchor) {
        uint256 anchor = _rateAtTarget[id];
        if (anchor == 0) anchor = INITIAL_RATE_AT_TARGET;

        uint256 utilization = market.totalSupplyAssets == 0
            ? 0
            // forge-lint: disable-next-line(unsafe-typecast)
            : uint256(market.totalBorrowAssets).wDivDown(market.totalSupplyAssets);
        if (utilization > WAD) utilization = WAD;

        // Error in WAD, signed: +WAD at full utilisation, -WAD at zero.
        int256 err;
        if (utilization > TARGET_UTILIZATION) {
            // forge-lint: disable-next-line(unsafe-typecast)
            err = int256((utilization - TARGET_UTILIZATION).wDivDown(WAD - TARGET_UTILIZATION));
        } else {
            // forge-lint: disable-next-line(unsafe-typecast)
            err = -int256((TARGET_UTILIZATION - utilization).wDivDown(TARGET_UTILIZATION));
        }

        // Slide the anchor, then clamp. Linear rather than exponential; see the contract note.
        uint256 elapsed = block.timestamp - market.lastUpdate;
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 drift = int256(ADJUSTMENT_SPEED * elapsed) * err / int256(WAD);
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 moved = int256(anchor) + (int256(anchor) * drift / int256(WAD));
        newAnchor = _clampAnchor(moved);

        // Apply the curve around the (new) anchor.
        int256 multiplier;
        if (err >= 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            multiplier = int256(WAD) + err * int256(CURVE_STEEPNESS - WAD) / int256(WAD);
        } else {
            uint256 downSlope = WAD - WAD.mulDivDown(WAD, CURVE_STEEPNESS);
            // forge-lint: disable-next-line(unsafe-typecast)
            multiplier = int256(WAD) + err * int256(downSlope) / int256(WAD);
        }
        // `multiplier` cannot be negative, so there is no floor here and no branch to test.
        // `err >= -WAD` by construction: in the branch above the numerator
        // `TARGET_UTILIZATION - utilization` is bounded by `TARGET_UTILIZATION` itself. With
        // `CURVE_STEEPNESS = 4e18` the down-slope is `WAD - WAD/4 = 0.75e18`, so the worst
        // case is `WAD - 0.75e18 = 0.25e18`. A `if (multiplier < 0) multiplier = 0;` used to
        // sit here and was unreachable — dead code that reads as a safeguard and is really a
        // claim no test can make fail. Raising `CURVE_STEEPNESS` above `4e18` does not break
        // this: the down-slope approaches but never reaches `WAD`.
        // forge-lint: disable-next-line(unsafe-typecast)
        rate = newAnchor.mulDivDown(uint256(multiplier), WAD);
    }

    function _clampAnchor(int256 value) internal pure returns (uint256) {
        // forge-lint: disable-next-line(unsafe-typecast)
        if (value < int256(MIN_RATE_AT_TARGET)) return MIN_RATE_AT_TARGET;
        // forge-lint: disable-next-line(unsafe-typecast)
        if (value > int256(MAX_RATE_AT_TARGET)) return MAX_RATE_AT_TARGET;
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint256(value);
    }
}
