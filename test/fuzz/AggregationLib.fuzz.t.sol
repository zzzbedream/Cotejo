// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {AggregationLib} from "../../src/libraries/AggregationLib.sol";
import {CotejoErrors} from "../../src/libraries/CotejoErrors.sol";
import {AggregationLibHarness} from "../helpers/AggregationLibHarness.sol";

/// @notice Property tests for the aggregation maths, over lengths 1 to 21, extreme values,
///         and heterogeneous decimals.
/// @dev Lengths run past `MAX_SOURCES_PER_ROUTE` (15) on purpose: the cap is the router's
///      policy, not the library's, and the library must not quietly depend on it.
contract AggregationLibFuzzTest is Test {
    uint256 private constant MIN_LEN = 1;
    uint256 private constant MAX_LEN = 21;

    AggregationLibHarness private harness;

    function setUp() public {
        harness = new AggregationLibHarness();
    }

    // --------------------------------------------------------------------------------
    // sortInPlace
    // --------------------------------------------------------------------------------

    function testFuzz_sortInPlace_producesAscendingOrder(uint256 seed, uint8 rawLen) public view {
        uint256[] memory xs = _buildSet(seed, rawLen, 1, 1e30);
        uint256[] memory out = harness.sorted(xs);

        for (uint256 i = 1; i < out.length; ++i) {
            assertLe(out[i - 1], out[i], "sort must be ascending");
        }
    }

    function testFuzz_sortInPlace_isAPermutation(uint256 seed, uint8 rawLen) public view {
        uint256[] memory xs = _buildSet(seed, rawLen, 1, 1e30);

        uint256 sumBefore;
        for (uint256 i; i < xs.length; ++i) {
            sumBefore += xs[i];
        }

        uint256[] memory out = harness.sorted(_copy(xs));

        uint256 sumAfter;
        for (uint256 i; i < out.length; ++i) {
            sumAfter += out[i];
        }

        assertEq(out.length, xs.length, "length must be preserved");
        assertEq(sumAfter, sumBefore, "sorting must not invent or drop values");
    }

    // --------------------------------------------------------------------------------
    // median
    // --------------------------------------------------------------------------------

    function testFuzz_median_matchesReferenceImplementation(uint256 seed, uint8 rawLen) public view {
        uint256[] memory xs = _buildSet(seed, rawLen, 1, 1e30);
        uint256[] memory sorted = harness.sorted(_copy(xs));

        uint256 expected;
        uint256 n = sorted.length;
        if (n % 2 == 1) {
            expected = sorted[n / 2];
        } else {
            uint256 lo = sorted[n / 2 - 1];
            uint256 hi = sorted[n / 2];
            expected = lo + (hi - lo) / 2;
        }

        assertEq(harness.median(sorted), expected, "median must match the reference");
    }

    function testFuzz_median_liesWithinTheSet(uint256 seed, uint8 rawLen) public view {
        uint256[] memory sorted = harness.sorted(_buildSet(seed, rawLen, 1, 1e30));
        uint256 med = harness.median(sorted);

        assertGe(med, sorted[0], "median cannot be below the minimum");
        assertLe(med, sorted[sorted.length - 1], "median cannot be above the maximum");
    }

    function testFuzz_median_singleElementIsThatElement(uint256 value) public view {
        value = bound(value, 1, type(uint256).max);
        uint256[] memory xs = new uint256[](1);
        xs[0] = value;
        assertEq(harness.median(xs), value);
    }

    function test_median_extremeValuesDoNotOverflow() public view {
        uint256[] memory xs = new uint256[](2);
        xs[0] = 1;
        xs[1] = type(uint256).max;

        // Naive (lo + hi) / 2 would overflow here; lo + (hi - lo) / 2 does not.
        uint256 med = harness.median(xs);
        assertEq(med, 1 + (type(uint256).max - 1) / 2);
    }

    function test_median_revertsOnEmptySet() public {
        vm.expectRevert(CotejoErrors.Cotejo__EmptySet.selector);
        harness.median(new uint256[](0));
    }

    // --------------------------------------------------------------------------------
    // deviationBps (D1: measured against the median)
    // --------------------------------------------------------------------------------

    function testFuzz_deviationBps_matchesFormula(uint256 seed, uint8 rawLen) public view {
        uint256[] memory sorted = harness.sorted(_buildSet(seed, rawLen, 1, 1e30));

        uint256 med = harness.median(sorted);
        uint256 spread = sorted[sorted.length - 1] - sorted[0];
        uint256 expected = (spread * AggregationLib.BPS_DENOMINATOR) / med;

        assertEq(harness.deviationBps(sorted), expected, "deviation must divide by the median");
    }

    function testFuzz_deviationBps_isZeroForUniformSets(uint256 value, uint8 rawLen) public view {
        value = bound(value, 1, 1e30);
        uint256 n = bound(rawLen, MIN_LEN, MAX_LEN);

        uint256[] memory xs = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            xs[i] = value;
        }

        assertEq(harness.deviationBps(xs), 0, "a set in perfect agreement has zero spread");
    }

    /// @dev The asymmetry that D1 introduces, pinned as a property rather than an anecdote:
    ///      for the same absolute spread, a high median yields a smaller figure than a low
    ///      one. This is why `maxDeviationBps` protects downward moves less strictly.
    function testFuzz_deviationBps_medianBaseIsAsymmetric(uint256 base, uint256 spread) public view {
        base = bound(base, 1e18, 1e24);
        spread = bound(spread, 1, base - 1);

        uint256[] memory majorityLow = new uint256[](3);
        majorityLow[0] = base;
        majorityLow[1] = base;
        majorityLow[2] = base + spread;

        uint256[] memory majorityHigh = new uint256[](3);
        majorityHigh[0] = base;
        majorityHigh[1] = base + spread;
        majorityHigh[2] = base + spread;

        uint256 upward = harness.deviationBps(majorityLow); // median == base
        uint256 downward = harness.deviationBps(majorityHigh); // median == base + spread

        assertGe(upward, downward, "a low outlier under a high majority is judged less harshly");
    }

    function test_deviationBps_revertsOnEmptySet() public {
        vm.expectRevert(CotejoErrors.Cotejo__EmptySet.selector);
        harness.deviationBps(new uint256[](0));
    }

    function test_deviationBps_overflowFailsClosed() public {
        // (max - min) * 10_000 overflows above roughly 1.15e73. Reverting is the intended
        // outcome: a number that large is not a price.
        uint256[] memory xs = new uint256[](2);
        xs[0] = 1;
        xs[1] = type(uint256).max;

        vm.expectRevert();
        harness.deviationBps(xs);
    }

    // --------------------------------------------------------------------------------
    // normalize (heterogeneous decimals)
    // --------------------------------------------------------------------------------

    function testFuzz_normalize_upscaleThenDownscaleRoundTrips(uint256 price, uint8 from, uint8 to)
        public
        view
    {
        from = uint8(bound(from, 0, 18));
        to = uint8(bound(to, from, 36));
        price = bound(price, 1, 1e30);

        uint256 up = harness.normalize(price, from, to);
        assertEq(harness.normalize(up, to, from), price, "upscale then downscale is lossless");
    }

    /// @dev Monotonicity is asserted only over the domain where `normalize` is total. A
    ///      downscale steep enough to round a value away reverts by design, so pairs that
    ///      would trip `Cotejo__PrecisionLoss` are excluded rather than treated as failures.
    function testFuzz_normalize_isMonotonicWhenUpscaling(uint256 a, uint256 b, uint8 from, uint8 to)
        public
        view
    {
        from = uint8(bound(from, 0, 18));
        to = uint8(bound(to, from, 36));
        a = bound(a, 1, 1e24);
        b = bound(b, a, 1e24 + 1);

        uint256 na = harness.normalize(a, from, to);
        uint256 nb = harness.normalize(b, from, to);
        assertLe(na, nb, "rescaling must preserve order");
    }

    /// @dev The same property on the downscale side, over values large enough that the
    ///      result is still representable at the target scale.
    function testFuzz_normalize_isMonotonicWhenDownscaling(uint256 a, uint256 b) public view {
        a = bound(a, 1e18, 1e30);
        b = bound(b, a, 1e30 + 1);

        uint256 na = harness.normalize(a, 18, 8);
        uint256 nb = harness.normalize(b, 18, 8);
        assertLe(na, nb, "rescaling must preserve order");
    }

    /// @dev Any downscale that would round a value to nothing reverts, whatever the inputs.
    function testFuzz_normalize_downscaleToZeroAlwaysReverts(uint256 price, uint8 delta) public {
        delta = uint8(bound(delta, 1, 30));
        uint256 divisor = 10 ** uint256(delta);
        price = bound(price, 1, divisor - 1);

        vm.expectRevert(abi.encodeWithSelector(CotejoErrors.Cotejo__PrecisionLoss.selector, price, delta, 0));
        harness.normalize(price, delta, 0);
    }

    function test_normalize_identityWhenDecimalsMatch() public view {
        assertEq(harness.normalize(123456, 8, 8), 123456);
    }

    function test_normalize_sixDecimalsToEighteen() public view {
        // USDW on Whitechain Sepolia carries 6 decimals, so this is the real conversion the
        // router performs when such a feed sits in a route.
        assertEq(harness.normalize(1_500_000, 6, 18), 1.5e18);
    }

    function test_normalize_revertsRatherThanRoundingToZero() public {
        // Downscaling 1 wei of an 18-decimal price to 8 decimals would yield zero. Returning
        // zero here would hand a consumer a zero price, which Cotejo never does.
        vm.expectRevert(abi.encodeWithSelector(CotejoErrors.Cotejo__PrecisionLoss.selector, 1, 18, 8));
        harness.normalize(1, 18, 8);
    }

    function test_normalize_revertsOnImplausibleDecimals() public {
        vm.expectRevert(abi.encodeWithSelector(CotejoErrors.Cotejo__DecimalsOutOfRange.selector, 37));
        harness.normalize(1e18, 37, 18);

        vm.expectRevert(abi.encodeWithSelector(CotejoErrors.Cotejo__DecimalsOutOfRange.selector, 99));
        harness.normalize(1e18, 18, 99);
    }

    function test_normalize_upscaleOverflowFailsClosed() public {
        vm.expectRevert();
        harness.normalize(type(uint256).max, 0, 36);
    }

    // --------------------------------------------------------------------------------
    // Helpers
    // --------------------------------------------------------------------------------

    function _buildSet(uint256 seed, uint8 rawLen, uint256 lo, uint256 hi)
        private
        pure
        returns (uint256[] memory xs)
    {
        uint256 n = _bound(rawLen, MIN_LEN, MAX_LEN);
        xs = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            xs[i] = _bound(uint256(keccak256(abi.encode(seed, i))), lo, hi);
        }
    }

    function _copy(uint256[] memory xs) private pure returns (uint256[] memory out) {
        out = new uint256[](xs.length);
        for (uint256 i; i < xs.length; ++i) {
            out[i] = xs[i];
        }
    }
}
