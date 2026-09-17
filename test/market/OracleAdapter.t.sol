// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {MarketTestBase} from "./helpers/MarketTestBase.sol";
import {MockERC20} from "./helpers/MockERC20.sol";
import {CotejoOracleAdapter} from "../../src/market/CotejoOracleAdapter.sol";
import {MarketErrors} from "../../src/market/libraries/MarketErrors.sol";
import {CotejoErrors} from "../../src/libraries/CotejoErrors.sol";
import {AttestationSource} from "../../src/sources/AttestationSource.sol";
import {IPriceRouter} from "../../src/interfaces/IPriceRouter.sol";

/// @notice The adapter's own surface: R8 policy enforcement, scaling, and introspection.
contract OracleAdapterTest is MarketTestBase {
    // --------------------------------------------------------------------------------
    // R8 — the routes cannot be weakened underneath a live market
    // --------------------------------------------------------------------------------

    /// @dev Without R8 every admission rule would be advisory: governance could admit a market
    ///      under a strict route and relax that route the following day. The adapter freezes
    ///      the policy at deployment and re-checks it on every read.
    function test_R8_revertsWhenQuorumIsLowered() public {
        _reRoute(COL_ASSET, 2, ROUTE_DEV_BPS, 5);

        vm.expectRevert(
            abi.encodeWithSelector(MarketErrors.Market__R8_RoutePolicyWeakened.selector, COL_ASSET)
        );
        adapter.price();
    }

    function test_R8_revertsWhenToleranceIsWidened() public {
        _reRoute(COL_ASSET, 3, ROUTE_DEV_BPS * 4, 5);

        vm.expectRevert(
            abi.encodeWithSelector(MarketErrors.Market__R8_RoutePolicyWeakened.selector, COL_ASSET)
        );
        adapter.price();
    }

    function test_R8_revertsWhenOperatorSpreadShrinks() public {
        // Same quorum and tolerance, but two of the five sources move under one operator, so
        // the route now spans four groups instead of five.
        vm.startPrank(owner);
        sources[4].setOperatorGroup(keccak256("operator0"));
        vm.stopPrank();

        vm.expectRevert(
            abi.encodeWithSelector(MarketErrors.Market__R8_RoutePolicyWeakened.selector, COL_ASSET)
        );
        adapter.price();
    }

    /// @dev Hardening a route is always allowed. Governance may tighten under a live market.
    function test_R8_allowsRoutesToBeHardened() public {
        _reRoute(COL_ASSET, 4, ROUTE_DEV_BPS / 2, 5);
        _refresh(0);

        assertGt(adapter.price(), 0, "a stricter route still serves");
    }

    function test_R8_policySnapshotIsReadable() public view {
        (uint8 minSources, uint16 devBps, uint8 groups) = adapter.policySnapshot(COL_ASSET);
        assertEq(minSources, 3);
        assertEq(devBps, ROUTE_DEV_BPS);
        assertEq(groups, 5, "five sources, five operators");

        (uint8 lMin,, uint8 lGroups) = adapter.policySnapshot(LOAN_ASSET);
        assertEq(lMin, 3);
        assertEq(lGroups, 5);
    }

    function test_R8_policySnapshotRejectsAnUnknownAsset() public {
        vm.expectRevert(MarketErrors.Market__InvalidParameter.selector);
        adapter.policySnapshot(keccak256("NOT/MINE"));
    }

    // --------------------------------------------------------------------------------
    // Scaling
    // --------------------------------------------------------------------------------

    /// @dev The price must carry the decimal difference between the two tokens, or every
    ///      solvency check would be wrong by a factor of 10^12 for an 18/6 pair.
    function test_priceCarriesTheDecimalDifference() public view {
        // WBT at $100, USDW at $1, collateral 18dp, loan 6dp.
        // 100 * 1e36 * 1e6 / 1e18 = 1e26.
        assertEq(adapter.price(), 1e26);
        assertEq(adapter.loanPriceUsd(), 1e18, "one dollar in WAD");
        assertEq(adapter.PRICE_SCALE(), 1e36);
    }

    function test_deviationCombinedSumsBothRoutes() public view {
        // 100 bps on each route.
        assertEq(adapter.deviationCombined(), 0.02e18);
    }

    function test_introspectionMatchesConstruction() public view {
        assertEq(adapter.router(), address(router));
        assertEq(adapter.collateralAsset(), COL_ASSET);
        assertEq(adapter.loanAsset(), LOAN_ASSET);
        assertEq(adapter.collateralTokenDecimals(), COL_DECIMALS);
        assertEq(adapter.loanTokenDecimals(), LOAN_DECIMALS);
    }

    // --------------------------------------------------------------------------------
    // Construction
    // --------------------------------------------------------------------------------

    function test_constructorRejectsDegenerateArguments() public {
        vm.expectRevert(MarketErrors.Market__InvalidParameter.selector);
        new CotejoOracleAdapter(address(0), COL_ASSET, LOAN_ASSET, 18, 6);

        vm.expectRevert(MarketErrors.Market__InvalidParameter.selector);
        new CotejoOracleAdapter(address(router), bytes32(0), LOAN_ASSET, 18, 6);

        vm.expectRevert(MarketErrors.Market__InvalidParameter.selector);
        new CotejoOracleAdapter(address(router), COL_ASSET, bytes32(0), 18, 6);

        // Same asset on both legs would make the price identically one and the market
        // meaningless.
        vm.expectRevert(MarketErrors.Market__InvalidParameter.selector);
        new CotejoOracleAdapter(address(router), COL_ASSET, COL_ASSET, 18, 6);
    }

    function test_constructorRejectsAnUnroutedAsset() public {
        vm.expectPartialRevert(MarketErrors.Market__R1_InsufficientRouteQuorum.selector);
        new CotejoOracleAdapter(address(router), keccak256("NOROUTE/USD"), LOAN_ASSET, 18, 6);
    }

    // --------------------------------------------------------------------------------
    // Degraded propagation
    // --------------------------------------------------------------------------------

    /// @dev The adapter never substitutes a value. Cotejo's typed error travels through it
    ///      unchanged, which is what lets the market name the invariant that stopped it.
    function test_propagatesTheRoutersTypedError() public {
        vm.prank(guardian);
        router.pause(COL_ASSET);

        vm.expectRevert(abi.encodeWithSelector(CotejoErrors.Cotejo__Paused.selector, COL_ASSET));
        adapter.price();

        vm.expectRevert(abi.encodeWithSelector(CotejoErrors.Cotejo__Paused.selector, COL_ASSET));
        adapter.bindingDepthUsd();
    }

    /// @dev Depth now travels the same gate as price, so a paused or out-of-tolerance route
    ///      cannot yield a debt ceiling either. Before that, `maxTotalBorrow` advertised a
    ///      number the protocol would not have honoured.
    function test_depthInheritsEveryPriceInvariant() public {
        _degradeByDeviation();

        vm.expectPartialRevert(CotejoErrors.Cotejo__DeviationExceeded.selector);
        adapter.bindingDepthUsd();
    }

    // --------------------------------------------------------------------------------

    function _degradeByDeviation() internal {
        vm.warp(block.timestamp + HEARTBEAT);
        for (uint256 i = 1; i < SOURCE_COUNT; ++i) {
            _attest(i, COL_ASSET, COL_PRICE_USD, BASE_DEPTH_USD, block.timestamp);
            _attest(i, LOAN_ASSET, LOAN_PRICE_USD, BASE_DEPTH_USD, block.timestamp);
        }
        _attest(0, COL_ASSET, COL_PRICE_USD * 50, BASE_DEPTH_USD, block.timestamp);
        _attest(0, LOAN_ASSET, LOAN_PRICE_USD, BASE_DEPTH_USD, block.timestamp);
    }

    /// @dev Replaces a live route through the governor, which is the only way it can change.
    function _reRoute(bytes32 asset, uint8 minSources, uint16 devBps, uint256 count) internal {
        address[] memory list = new address[](count);
        for (uint256 i; i < count; ++i) {
            list[i] = address(sources[i]);
        }

        vm.prank(owner);
        governor.proposeRoute(
            asset,
            IPriceRouter.Route({
                sources: list,
                minSources: minSources,
                maxDeviationBps: devBps,
                maxStalenessSeconds: STALENESS,
                reporterHeartbeatSeconds: HEARTBEAT,
                maxSourcesPerOperatorGroup: 1
            })
        );
        vm.warp(block.timestamp + governor.ROUTE_TIMELOCK());
        governor.executeRoute(asset);
    }
}
