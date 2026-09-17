// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {TwapSource} from "../../src/sources/TwapSource.sol";
import {PriceRouter} from "../../src/PriceRouter.sol";
import {RouteGovernor} from "../../src/RouteGovernor.sol";
import {IPriceRouter} from "../../src/interfaces/IPriceRouter.sol";
import {CotejoErrors} from "../../src/libraries/CotejoErrors.sol";

/// @notice Documents, as executable assertions, why TWAP is switched off in v1.
///
/// @dev This is the test that exists so the reasoning does not rot into a comment nobody
///      re-reads. The evidence, from Whitechain's own documentation:
///
///        - Swaps are stated to be "not available on any testnet". WhiteSwap exists as a
///          first-party product, but not as something a contract can read on Sepolia today.
///        - A contract labelled `UniswapV3Pool` *does* exist on Whitechain Sepolia, at
///          0x6e057133CFa4a9Ec70c77aaFe29751460FE16307 — it shows up in the explorer's own
///          indexing examples as a holder of the testnet USDW token.
///
///      The second point is why this is a skeleton rather than an empty file. A pool exists,
///      so someone will eventually be tempted to point a TWAP at it. What does not exist is
///      anything that would make reading it safe: no documented factory, no published pool
///      addresses, no liquidity floor, no swap flow to build observation cardinality from.
///
///      A TWAP over a pool with negligible depth is not a price. It is a number an attacker
///      sets for the cost of moving a thin pool, with time-weighting deciding only how many
///      blocks they must hold it. Whitechain produces a block every second, so a 30-minute
///      window is 1,800 blocks of a cheap position — not the deterrent it is on a 12-second
///      chain. Wiring this up early would hand a route a source that looks independent and
///      is not, which is precisely the failure `CircularPricingTest` covers from the other
///      direction.
contract TwapDisabledTest is Test {
    bytes32 private constant WBT_USD = keccak256("WBT/USD");

    /// @dev The pool address from the Whitechain indexing examples. Referenced here as the
    ///      concrete thing a future implementer would reach for, not as a configured source.
    address private constant OBSERVED_TESTNET_POOL = 0x6e057133CFa4a9Ec70c77aaFe29751460FE16307;

    TwapSource private twap;

    function setUp() public {
        twap = new TwapSource(OBSERVED_TESTNET_POOL, WBT_USD);
    }

    function test_TwapDisabled_latestPriceReverts() public {
        vm.expectRevert(CotejoErrors.Cotejo__TwapDisabled.selector);
        twap.latestPrice(WBT_USD);
    }

    function test_TwapDisabled_reportsNoAssetSupport() public view {
        assertFalse(twap.supportsAsset(WBT_USD), "v1 TWAP must not claim to serve any asset");
        assertEq(twap.operatorGroupOf(WBT_USD), bytes32(0), "no operator group in v1");
    }

    /// @dev The load-bearing assertion. Because `supportsAsset` is false, a route naming this
    ///      source is rejected at proposal time — the source cannot be switched on by
    ///      configuration alone, only by shipping an implementation.
    function test_TwapDisabled_cannotBeCommittedIntoARoute() public {
        address owner = makeAddr("owner");
        PriceRouter router = new PriceRouter(owner);
        RouteGovernor governor = new RouteGovernor(address(router), owner);

        vm.prank(owner);
        router.setGovernor(address(governor));

        address[] memory sources = new address[](1);
        sources[0] = address(twap);

        IPriceRouter.Route memory route = IPriceRouter.Route({
            sources: sources,
            minSources: 1,
            maxDeviationBps: 500,
            maxStalenessSeconds: 900,
            reporterHeartbeatSeconds: 300,
            maxSourcesPerOperatorGroup: 1
        });

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                CotejoErrors.Cotejo__SourceDoesNotServeAsset.selector, address(twap), WBT_USD
            )
        );
        governor.proposeRoute(WBT_USD, route);
    }

    function test_TwapDisabled_retainsIntendedConfigurationForV2() public view {
        assertEq(twap.POOL(), OBSERVED_TESTNET_POOL);
        assertEq(twap.ASSET(), WBT_USD);
    }
}
