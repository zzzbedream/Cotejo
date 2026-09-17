// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {MarketTestBase} from "./helpers/MarketTestBase.sol";
import {MockERC20} from "./helpers/MockERC20.sol";
import {AttestationSource} from "../../src/sources/AttestationSource.sol";
import {IPriceRouter} from "../../src/interfaces/IPriceRouter.sol";
import {CotejoOracleAdapter} from "../../src/market/CotejoOracleAdapter.sol";
import {AdaptiveCurveIrm} from "../../src/market/AdaptiveCurveIrm.sol";
import {MarketParams} from "../../src/market/types/MarketTypes.sol";
import {MarketErrors} from "../../src/market/libraries/MarketErrors.sol";
import {CotejoErrors} from "../../src/libraries/CotejoErrors.sol";

/// @notice R1 through R8, each rejected at creation.
contract AdmissionRulesTest is MarketTestBase {
    /// @notice R2. Three shell sources, one operator. The quorum is theatre.
    ///
    /// @dev The failure this catches is the one that keeps reaching production: a route names
    ///      several distinct contract addresses, passes every count-based check, and is in
    ///      fact one desk wearing several hats. Compromise the desk and every "independent"
    ///      source moves together, the deviation stays at zero, and the oracle publishes a
    ///      manipulated price with total confidence. An asset that cannot be valued
    ///      independently cannot be collateral — no exception, no governance parameter that
    ///      relaxes it.
    function test_R2_rejectsCollateralWithConcentratedOracle() public {
        bytes32 asset = keccak256("SHELL/USD");
        MockERC20 shellToken = new MockERC20("Shell", "SHL", 18);

        vm.prank(owner);
        governor.registerAssetToken(asset, address(shellToken));

        // Five addresses, two operators. The router itself will accept this once its own
        // per-group cap is loosened; the market will not.
        bytes32 sharedGroup = keccak256("one-desk");
        address[] memory shells = new address[](5);
        for (uint256 i; i < 5; ++i) {
            AttestationSource s = new AttestationSource(
                "Cotejo",
                "1",
                keccak256(abi.encode("shell", i)),
                i < 4 ? sharedGroup : keccak256("second-desk"),
                owner
            );
            vm.prank(owner);
            s.setAsset(asset, true, 1);
            shells[i] = address(s);
        }

        vm.prank(owner);
        governor.proposeRoute(
            asset,
            IPriceRouter.Route({
                sources: shells,
                minSources: 3,
                maxDeviationBps: ROUTE_DEV_BPS,
                maxStalenessSeconds: STALENESS,
                reporterHeartbeatSeconds: HEARTBEAT,
                maxSourcesPerOperatorGroup: 4 // loosened, so the router admits it
            })
        );
        vm.warp(block.timestamp + governor.ROUTE_TIMELOCK());
        governor.executeRoute(asset);

        CotejoOracleAdapter shellAdapter =
            new CotejoOracleAdapter(address(router), asset, LOAN_ASSET, 18, LOAN_DECIMALS);

        MarketParams memory bad = MarketParams({
            collateralToken: address(shellToken),
            loanToken: address(loan),
            oracleAdapter: address(shellAdapter),
            irm: address(irm),
            lltv: LLTV
        });

        // Two distinct groups across five sources is one short of the floor.
        vm.expectRevert(
            abi.encodeWithSelector(MarketErrors.Market__R2_ConcentratedOracle.selector, asset, 2, 3)
        );
        market.createMarket(bad, LIF);
    }

    /// @notice R1. A route that prices from fewer than three sources cannot back a market.
    function test_R1_rejectsThinQuorum() public {
        (bytes32 asset, MockERC20 token) = _routeWith(5, 2, ROUTE_DEV_BPS, "THIN");
        MarketParams memory p = _paramsFor(asset, token);

        vm.expectRevert(
            abi.encodeWithSelector(MarketErrors.Market__R1_InsufficientRouteQuorum.selector, asset, 2, 3)
        );
        market.createMarket(p, LIF);
    }

    /// @notice R3. LLTV above the ceiling is refused.
    function test_R3_rejectsExcessiveLltv() public {
        MarketParams memory p = params;
        p.lltv = 0.87e18;

        vm.expectRevert(
            abi.encodeWithSelector(MarketErrors.Market__R3_LltvTooHigh.selector, 0.87e18, market.MAX_LLTV())
        );
        market.createMarket(p, LIF);
    }

    /// @notice R4. An unlisted interest rate model is refused.
    function test_R4_rejectsUnlistedIrm() public {
        AdaptiveCurveIrm rogue = new AdaptiveCurveIrm(address(market));
        MarketParams memory p = params;
        p.irm = address(rogue);

        vm.expectRevert(
            abi.encodeWithSelector(MarketErrors.Market__R4_IrmNotWhitelisted.selector, address(rogue))
        );
        market.createMarket(p, LIF);
    }

    /// @notice R5. The incentive is capped by what the route tolerance allows.
    /// @dev With both routes at 100 bps the combined tolerance is 200 bps, so
    ///      `(1 - 0.02) / 0.86 = 1.139535`. Anything above that lets a liquidation extract
    ///      value at the largest price error the oracle will still serve.
    function test_R5_rejectsIncentiveAboveDerivedBound() public {
        uint256 devCombined = 0.02e18;
        uint256 derived = (uint256(1e18) - devCombined) * 1e18 / LLTV;
        assertEq(derived, 1_139_534_883_720_930_232, "derivation must match the documented figure");

        uint256 altLltv = 0.85e18;
        MarketParams memory p = params;
        p.lltv = altLltv; // a distinct market

        uint256 boundForThis = (uint256(1e18) - devCombined) * 1e18 / altLltv;
        uint256 effective =
            boundForThis < market.MAX_LIF_ABSOLUTE() ? boundForThis : market.MAX_LIF_ABSOLUTE();

        vm.expectRevert(
            abi.encodeWithSelector(
                MarketErrors.Market__R5_IncentiveTooHigh.selector, effective + 1, effective
            )
        );
        market.createMarket(p, effective + 1);
    }

    /// @notice R5. The absolute ceiling binds where the derived bound is permissive.
    /// @dev At a low LLTV the formula allows an enormous bonus — 1.96 at 50% — which does not
    ///      extract value through oracle error but does gouge the borrower. Two different
    ///      concerns, two different bounds.
    function test_R5_absoluteCeilingBindsAtLowLltv() public {
        uint256 lowLltv = 0.5e18;
        MarketParams memory p = params;
        p.lltv = lowLltv;

        uint256 derived = (uint256(1e18) - uint256(0.02e18)) * 1e18 / lowLltv;
        assertEq(derived, 1.96e18, "the formula alone would permit a 96% bonus");

        uint256 ceiling = market.MAX_LIF_ABSOLUTE();
        vm.expectRevert(
            abi.encodeWithSelector(MarketErrors.Market__R5_IncentiveTooHigh.selector, ceiling + 1, ceiling)
        );
        market.createMarket(p, ceiling + 1);

        // At the ceiling it is accepted.
        market.createMarket(p, ceiling);
    }

    /// @notice R5. A route so loose that no liquidator would ever act is refused outright.
    function test_R5_rejectsRouteWithNoViableIncentive() public {
        (bytes32 asset, MockERC20 token) = _routeWith(5, 3, 1_000, "LOOSE");
        // 1000 + 100 bps combined = 11% against an LLTV of 86%: (1 - 0.11)/0.86 = 1.0349,
        // still viable. Push the collateral route wide enough that it is not.
        (bytes32 wide, MockERC20 wideToken) = _routeWith(5, 3, 4_000, "WIDE");
        asset = wide;
        token = wideToken;

        CotejoOracleAdapter wideAdapter =
            new CotejoOracleAdapter(address(router), asset, LOAN_ASSET, 18, LOAN_DECIMALS);
        MarketParams memory p = MarketParams({
            collateralToken: address(token),
            loanToken: address(loan),
            oracleAdapter: address(wideAdapter),
            irm: address(irm),
            lltv: LLTV
        });

        // 4000 + 100 bps = 41% combined. (1 - 0.41)/0.86 = 0.686 < 1: the liquidator would
        // receive less than they repay.
        vm.expectRevert(
            abi.encodeWithSelector(MarketErrors.Market__R5_NoViableIncentive.selector, 0.41e18, LLTV)
        );
        market.createMarket(p, LIF);
    }

    /// @notice R6. The adapter must price the token the market actually custodies.
    /// @dev Without this, R1 and R2 validate a feed that might describe something else
    ///      entirely, and every guarantee downstream of them is vacuous.
    function test_R6_rejectsAssetTokenMismatch() public {
        MockERC20 impostor = new MockERC20("Impostor", "IMP", 18);
        MarketParams memory p = params;
        p.collateralToken = address(impostor);

        vm.expectRevert(
            abi.encodeWithSelector(
                MarketErrors.Market__R6_AssetTokenMismatch.selector,
                COL_ASSET,
                address(collateral),
                address(impostor)
            )
        );
        market.createMarket(p, LIF);
    }

    /// @notice R6. An unregistered asset cannot back a market at all.
    function test_R6_rejectsUnregisteredAsset() public {
        (bytes32 asset, MockERC20 token) = _routeWithoutRegistration("UNREG");
        MarketParams memory p = _paramsFor(asset, token);

        vm.expectRevert(
            abi.encodeWithSelector(
                MarketErrors.Market__R6_AssetTokenMismatch.selector, asset, address(0), address(token)
            )
        );
        market.createMarket(p, LIF);
    }

    /// @notice The registry is append-only, so a mapping cannot be repointed later.
    function test_R6_registryIsAppendOnly() public {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                CotejoErrors.Cotejo__AssetAlreadyRegistered.selector, COL_ASSET, address(collateral)
            )
        );
        governor.registerAssetToken(COL_ASSET, address(loan));
    }

    /// @notice R7. Three sources at a quorum of three leaves no redundancy.
    /// @dev One reporter outage would drop the route below quorum, degrade the oracle, and —
    ///      because degraded mode blocks liquidation — freeze the market's entire solvency
    ///      control. A 1-of-3 liveness dependency for safety is not acceptable.
    function test_R7_rejectsRouteWithoutRedundancy() public {
        (bytes32 asset, MockERC20 token) = _routeWith(3, 3, ROUTE_DEV_BPS, "TIGHT");
        MarketParams memory p = _paramsFor(asset, token);

        vm.expectRevert(
            abi.encodeWithSelector(MarketErrors.Market__R7_InsufficientRedundancy.selector, asset, 3, 5)
        );
        market.createMarket(p, LIF);
    }

    function test_R7_acceptsExactlyMinSourcesPlusTwo() public {
        (bytes32 asset, MockERC20 token) = _routeWith(5, 3, ROUTE_DEV_BPS, "OK5");
        market.createMarket(_paramsFor(asset, token), LIF);
    }

    /// @notice A market cannot be created twice.
    function test_rejectsDuplicateMarket() public {
        vm.expectRevert(abi.encodeWithSelector(MarketErrors.Market__AlreadyCreated.selector, id));
        market.createMarket(params, LIF);
    }

    // --------------------------------------------------------------------------------
    // Helpers
    // --------------------------------------------------------------------------------

    function _paramsFor(bytes32 asset, MockERC20 token) internal returns (MarketParams memory) {
        CotejoOracleAdapter a = new CotejoOracleAdapter(address(router), asset, LOAN_ASSET, 18, LOAN_DECIMALS);
        return MarketParams({
            collateralToken: address(token),
            loanToken: address(loan),
            oracleAdapter: address(a),
            irm: address(irm),
            lltv: LLTV
        });
    }

    /// @dev Builds a route with `count` sources in distinct operator groups, at the given
    ///      quorum and tolerance, and registers its token.
    function _routeWith(uint256 count, uint8 minSources, uint16 devBps, string memory tag)
        internal
        returns (bytes32 asset, MockERC20 token)
    {
        (asset, token) = _routeWithoutRegistration(tag);
        vm.prank(owner);
        governor.registerAssetToken(asset, address(token));
        _buildRoute(asset, count, minSources, devBps, tag);
    }

    function _routeWithoutRegistration(string memory tag) internal returns (bytes32 asset, MockERC20 token) {
        asset = keccak256(bytes(string.concat(tag, "/USD")));
        token = new MockERC20(tag, tag, 18);
        _buildRoute(asset, 5, 3, ROUTE_DEV_BPS, tag);
    }

    function _buildRoute(bytes32 asset, uint256 count, uint8 minSources, uint16 devBps, string memory tag)
        internal
    {
        address[] memory list = new address[](count);
        for (uint256 i; i < count; ++i) {
            AttestationSource s = new AttestationSource(
                "Cotejo",
                "1",
                keccak256(abi.encode(tag, "src", i)),
                keccak256(abi.encode(tag, "group", i)),
                owner
            );
            vm.prank(owner);
            s.setAsset(asset, true, 1);
            list[i] = address(s);
        }

        (,, bool pending) = governor.getPendingRoute(asset);
        if (pending) {
            vm.prank(owner);
            governor.cancelRoute(asset);
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
