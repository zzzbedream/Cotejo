// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {CotejoTestBase} from "../helpers/CotejoTestBase.sol";
import {MockPriceSource} from "../helpers/MockPriceSource.sol";
import {AttestationSource} from "../../src/sources/AttestationSource.sol";
import {ChainlinkCompatSource} from "../../src/sources/ChainlinkCompatSource.sol";
import {MockAggregatorV3} from "../helpers/MockAggregatorV3.sol";
import {CotejoErrors} from "../../src/libraries/CotejoErrors.sol";

/// @notice Guards on the oracle layer's read surface that no other test reached.
///
/// @dev Depth is newer than price in this codebase and it shows: `latestDepthUsd` grew its own
///      refusals on every source and none of them had a test. Depth feeds the market's borrow
///      ceiling, so a guard that silently returns the wrong thing here becomes a borrow limit
///      computed from nothing.
contract OracleGuardsTest is CotejoTestBase {
    bytes32 private constant OTHER_ASSET = keccak256("ETH/USD");

    // --------------------------------------------------------------------------------
    // R6 — the asset/token registry
    // --------------------------------------------------------------------------------

    /// @dev The registry is append-only and is what R6 checks a market's tokens against. A
    ///      zero entry on either side would bind an identifier to nothing, and every later
    ///      admission check against it would pass vacuously.
    function test_assetTokenRegistryRejectsZeroOnEitherSide() public {
        address token = makeAddr("token");

        vm.prank(owner);
        vm.expectRevert(CotejoErrors.Cotejo__InvalidRouteParameter.selector);
        governor.registerAssetToken(bytes32(0), token);

        vm.prank(owner);
        vm.expectRevert(CotejoErrors.Cotejo__InvalidRouteParameter.selector);
        governor.registerAssetToken(WBT_USD, address(0));
    }

    // --------------------------------------------------------------------------------
    // Depth on the router
    // --------------------------------------------------------------------------------

    /// @notice A one-source route reports no second-lowest depth, which is a zero ceiling.
    ///
    /// @dev M1 takes the *second*-lowest depth precisely so one source cannot set the borrow
    ///      limit by itself. With a single source there is no second-lowest, and the honest
    ///      answer is zero rather than reusing the only reading available — reusing it would
    ///      hand exactly the power M1 exists to remove to exactly the source M1 distrusts.
    ///      Zero propagates to a zero ceiling, so the route serves a price and finances
    ///      nothing.
    function test_singleSourceRouteHasNoSecondLowestDepth() public {
        _commitRoute(WBT_USD, _routeWith(_addressArray(address(sourceA)), 1, 500));

        sourceA.set(100e18, 18, block.timestamp);
        sourceA.setDepth(750_000);

        (uint256 lowest, uint256 secondLowest, uint256 count) = router.latestDepth(WBT_USD);

        assertEq(count, 1, "one fresh source");
        assertEq(lowest, 750_000, "the lowest is the only reading");
        assertEq(secondLowest, 0, "there is no second-lowest, and zero is the fail-closed answer");
    }

    /// @notice A source that serves a price but refuses a depth counts as zero depth, not as a
    ///         failed read.
    ///
    /// @dev The price path drops a reverting source and carries on (INV-1); the depth path has
    ///      to do something narrower, because a missing depth is not a missing source. It is
    ///      caught and recorded as zero, which drags the second-lowest down and tightens the
    ///      ceiling. Failing the whole read instead would let any one source freeze borrowing
    ///      across every market on the route.
    function test_sourceThatRefusesDepthCountsAsZeroRatherThanFailingTheRead() public {
        _commitRoute(WBT_USD, _defaultRoute());
        _setAllPrices(100e18);
        sourceA.setDepth(900_000);
        sourceB.setDepth(800_000);
        sourceC.setDepth(700_000);

        (, uint256 healthySecond,) = router.latestDepth(WBT_USD);
        assertEq(healthySecond, 800_000, "baseline: the middle reading");

        sourceC.setDepthReverts(true);

        // The price still serves: this source is up, it just has no book to report.
        (uint256 price,,) = router.latestPrice(WBT_USD);
        assertEq(price, 100e18, "a missing depth must not take the price down with it");

        (uint256 lowest, uint256 secondLowest, uint256 count) = router.latestDepth(WBT_USD);
        assertEq(count, 3, "the source is still counted, it is not dropped");
        assertEq(lowest, 0, "its depth reads as zero");
        assertEq(secondLowest, 800_000, "and the ceiling tightens to the next real reading");
    }

    // --------------------------------------------------------------------------------
    // Depth on the sources
    // --------------------------------------------------------------------------------

    function test_attestationSourceRefusesDepthForUnknownOrUnreportedAssets() public {
        AttestationSource source =
            new AttestationSource("Cotejo", "1", keccak256("cotejo.source.test"), GROUP_A, owner);

        // Never enabled: the source has no opinion about this asset at all.
        vm.expectRevert(abi.encodeWithSelector(CotejoErrors.Cotejo__AssetNotSupported.selector, OTHER_ASSET));
        source.latestDepthUsd(OTHER_ASSET);

        // Enabled, but nothing has ever been attested. Distinct from "supported with zero
        // depth", which would read as a real order book of size zero.
        vm.prank(owner);
        source.setAsset(WBT_USD, true, 1);

        vm.expectRevert(abi.encodeWithSelector(CotejoErrors.Cotejo__NoPrice.selector, WBT_USD));
        source.latestDepthUsd(WBT_USD);
    }

    /// @dev `ChainlinkCompatSource` answers zero depth by design — a Chainlink feed publishes a
    ///      price and knows nothing about a book — which is what keeps a route containing one
    ///      from backing a lending market. The asset guard in front of it still has to hold,
    ///      or the zero would be returned for assets this source does not even serve.
    function test_chainlinkCompatSourceGuardsItsAssetBeforeAnsweringZeroDepth() public {
        MockAggregatorV3 feed = new MockAggregatorV3();
        ChainlinkCompatSource source = new ChainlinkCompatSource(address(feed), WBT_USD, GROUP_A, owner);

        assertEq(source.latestDepthUsd(WBT_USD), 0, "no book behind a price feed, stated as zero");

        vm.expectRevert(abi.encodeWithSelector(CotejoErrors.Cotejo__AssetNotSupported.selector, OTHER_ASSET));
        source.latestDepthUsd(OTHER_ASSET);
    }
}
