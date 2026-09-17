// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {CotejoErrors} from "./CotejoErrors.sol";

/// @title AggregationLib
/// @notice Pure statistics over a price set: sort, median, spread, decimal normalisation.
/// @dev Stateless and `pure` throughout, so the whole read path stays `view` (D3).
library AggregationLib {
    /// @notice Basis-point denominator. 10_000 bps = 100%.
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    /// @notice Hard cap on sources per route (D4).
    /// @dev Bounds the cost of a `latestPrice` read, which is what matters when a
    ///      liquidator calls it under pressure. Also keeps the O(n^2) insertion sort
    ///      cheaper than any heap or merge variant at this size.
    uint8 internal constant MAX_SOURCES_PER_ROUTE = 15;

    /// @notice Largest decimals exponent accepted by `normalize`.
    uint8 internal constant MAX_DECIMALS = 36;

    /// @notice Sorts `xs` ascending, in place, with an insertion sort.
    /// @dev O(n^2), deliberately. With n <= 15 (D4) it beats every alternative on gas and
    ///      it is auditable at a glance, which matters more here than asymptotics.
    ///      Mutates the caller's memory array; callers pass a scratch array they own.
    /// @param xs Array to sort in place.
    function sortInPlace(uint256[] memory xs) internal pure {
        uint256 n = xs.length;
        for (uint256 i = 1; i < n; ++i) {
            uint256 key = xs[i];
            uint256 j = i;
            while (j != 0 && xs[j - 1] > key) {
                xs[j] = xs[j - 1];
                unchecked {
                    --j;
                }
            }
            xs[j] = key;
        }
    }

    /// @notice Median of an ascending-sorted set.
    /// @dev For an even count this returns the average of the two central values, rounded
    ///      down. That synthesises a value no source reported, which is acceptable because
    ///      INV-2 has already bounded how far apart the set can be. Computed as
    ///      `lo + (hi - lo) / 2` so the intermediate sum cannot overflow.
    /// @param sorted Ascending-sorted, non-empty price set.
    /// @return med The median value.
    function median(uint256[] memory sorted) internal pure returns (uint256 med) {
        uint256 n = sorted.length;
        if (n == 0) revert CotejoErrors.Cotejo__EmptySet();

        uint256 mid = n / 2;
        if (n % 2 == 1) return sorted[mid];

        uint256 lo = sorted[mid - 1];
        uint256 hi = sorted[mid];
        return lo + (hi - lo) / 2;
    }

    /// @notice Spread across the set, in basis points, measured against the median.
    ///
    /// @dev D1: `(max - min) * 10_000 / median`. The median is the base, not the min and
    ///      not the max. This changes the meaning of the threshold, and the change is not
    ///      symmetric — for the same absolute spread, the reported figure depends on which
    ///      side the majority sits:
    ///
    ///        [100, 100, 200] -> median 100, spread 100 -> 10_000 bps
    ///        [100, 200, 200] -> median 200, spread 100 ->  5_000 bps
    ///
    ///      A low outlier under a high majority is judged about half as harshly as the
    ///      mirrored case, because it divides by a larger median. That is the direction
    ///      that triggers liquidations, so `maxDeviationBps` protects asymmetrically and a
    ///      route should be tuned with the downward case in mind.
    ///
    ///      `median` is non-zero in practice because every source rejects a zero price
    ///      before the router ever sees it, so the division cannot trap on a live set.
    ///
    ///      `(max - min) * BPS_DENOMINATOR` reverts on overflow above roughly 1.15e73.
    ///      That revert is intentional and is not wrapped in a mulDiv: an input that large
    ///      is not a price, and failing closed is the correct response.
    ///
    /// @param sorted Ascending-sorted, non-empty price set.
    /// @return bps Spread in basis points relative to the median.
    function deviationBps(uint256[] memory sorted) internal pure returns (uint256 bps) {
        uint256 n = sorted.length;
        if (n == 0) revert CotejoErrors.Cotejo__EmptySet();

        uint256 med = median(sorted);
        uint256 spread = sorted[n - 1] - sorted[0];
        return (spread * BPS_DENOMINATOR) / med;
    }

    /// @notice Rescales `price` from `from` decimals to `to` decimals.
    /// @dev Reverts rather than returning zero when a downscale would round the value away
    ///      entirely. Returning zero here would hand a consumer a price of zero, which is
    ///      exactly the failure mode Cotejo refuses to produce.
    ///      An upscale that overflows reverts under 0.8 checked arithmetic, which is again
    ///      the fail-closed outcome.
    /// @param price Value to rescale.
    /// @param from Decimals `price` is currently scaled by.
    /// @param to Target decimals.
    /// @return scaled The rescaled value.
    function normalize(uint256 price, uint8 from, uint8 to) internal pure returns (uint256 scaled) {
        if (from > MAX_DECIMALS) revert CotejoErrors.Cotejo__DecimalsOutOfRange(from);
        if (to > MAX_DECIMALS) revert CotejoErrors.Cotejo__DecimalsOutOfRange(to);

        if (from == to) return price;

        if (to > from) {
            // The exponent is bounded by MAX_DECIMALS, so 10 ** delta cannot overflow and
            // the subtraction is guarded by the branch. The multiplication stays checked
            // on purpose: an upscale that overflows must revert, not wrap.
            uint256 factor;
            unchecked {
                factor = 10 ** uint256(to - from);
            }
            return price * factor;
        }

        uint256 divisor;
        unchecked {
            divisor = 10 ** uint256(from - to);
        }
        scaled = price / divisor;
        if (scaled == 0) revert CotejoErrors.Cotejo__PrecisionLoss(price, from, to);
    }
}
