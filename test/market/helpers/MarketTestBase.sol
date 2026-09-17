// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {PriceRouter} from "../../../src/PriceRouter.sol";
import {RouteGovernor} from "../../../src/RouteGovernor.sol";
import {AttestationSource} from "../../../src/sources/AttestationSource.sol";
import {IPriceRouter} from "../../../src/interfaces/IPriceRouter.sol";

import {CotejoMarket} from "../../../src/market/CotejoMarket.sol";
import {CotejoOracleAdapter} from "../../../src/market/CotejoOracleAdapter.sol";
import {AdaptiveCurveIrm} from "../../../src/market/AdaptiveCurveIrm.sol";
import {Id, MarketParams} from "../../../src/market/types/MarketTypes.sol";
import {MockERC20} from "./MockERC20.sol";

/// @notice Shared wiring for phase-2 tests.
///
/// @dev Deliberately production-shaped: **five** `AttestationSource` instances across five
///      distinct operator groups, because R7 requires `sources >= minSources + 2` and a
///      three-source route would leave the market one reporter outage away from a frozen
///      liquidation path. Every asset is served by all five.
abstract contract MarketTestBase is Test {
    // Assets
    bytes32 internal constant COL_ASSET = keccak256("WBT/USD");
    bytes32 internal constant LOAN_ASSET = keccak256("USDW/USD");

    uint256 internal constant SOURCE_COUNT = 5;
    uint32 internal constant STALENESS = 900;
    uint32 internal constant HEARTBEAT = 300;
    uint16 internal constant ROUTE_DEV_BPS = 100;

    uint8 internal constant COL_DECIMALS = 18;
    uint8 internal constant LOAN_DECIMALS = 6;

    uint256 internal constant LLTV = 0.86e18;
    uint256 internal constant LIF = 1.1e18;
    uint256 internal constant DEPTH_MULTIPLIER_BPS = 5_000;
    /// @dev A1.1. Above the depth-derived cap in the baseline fixture, so the depth mechanism
    ///      is what binds here; dedicated tests lower it to exercise the ceiling itself.
    uint256 internal constant MAX_ADAPTER_DEBT_USD = 5_000_000;

    // Baseline prices, both in 18 decimals as the reporters publish them.
    uint256 internal constant COL_PRICE_USD = 100e18; // WBT at $100
    uint256 internal constant LOAN_PRICE_USD = 1e18; // USDW at $1
    uint256 internal constant BASE_DEPTH_USD = 4_000_000;

    address internal owner = makeAddr("owner");
    address internal guardian = makeAddr("guardian");
    address internal supplier = makeAddr("supplier");
    address internal borrower = makeAddr("borrower");
    address internal liquidator = makeAddr("liquidator");
    address internal attacker = makeAddr("attacker");

    PriceRouter internal router;
    RouteGovernor internal governor;
    AttestationSource[SOURCE_COUNT] internal sources;
    uint256[SOURCE_COUNT] internal reporterKeys;
    address[SOURCE_COUNT] internal reporters;

    MockERC20 internal collateral;
    MockERC20 internal loan;

    CotejoMarket internal market;
    AdaptiveCurveIrm internal irm;
    CotejoOracleAdapter internal adapter;
    MarketParams internal params;
    Id internal id;

    function setUp() public virtual {
        vm.warp(1_750_000_000);

        collateral = new MockERC20("Whitechain Token", "WBT", COL_DECIMALS);
        loan = new MockERC20("USD Whitechain", "USDW", LOAN_DECIMALS);

        _deployOracleStack();

        market = new CotejoMarket(owner, DEPTH_MULTIPLIER_BPS, MAX_ADAPTER_DEBT_USD);
        irm = new AdaptiveCurveIrm(address(market));
        _whitelistIrm(address(irm));

        // Seeded last: every timelock warp above would otherwise leave the attestations stale
        // before the first test line runs.
        _seedPrices(COL_PRICE_USD, LOAN_PRICE_USD, BASE_DEPTH_USD);

        adapter = new CotejoOracleAdapter(address(router), COL_ASSET, LOAN_ASSET, COL_DECIMALS, LOAN_DECIMALS);

        params = MarketParams({
            collateralToken: address(collateral),
            loanToken: address(loan),
            oracleAdapter: address(adapter),
            irm: address(irm),
            lltv: LLTV
        });
        id = market.createMarket(params, LIF);

        _fund();
    }

    // --------------------------------------------------------------------------------
    // Oracle stack
    // --------------------------------------------------------------------------------

    function _deployOracleStack() internal {
        router = new PriceRouter(owner);
        governor = new RouteGovernor(address(router), owner);

        vm.startPrank(owner);
        router.setGovernor(address(governor));
        // R6: bind each asset identifier to the token it prices. Append-only.
        governor.registerAssetToken(COL_ASSET, address(collateral));
        governor.registerAssetToken(LOAN_ASSET, address(loan));
        vm.stopPrank();

        _grantGuardian(guardian);

        address[] memory routeSources = new address[](SOURCE_COUNT);

        for (uint256 i; i < SOURCE_COUNT; ++i) {
            string memory group = string.concat("operator", vm.toString(i));
            sources[i] = new AttestationSource(
                "Cotejo",
                "1",
                keccak256(bytes(string.concat("cotejo.source.", group))),
                keccak256(bytes(group)),
                owner
            );
            routeSources[i] = address(sources[i]);
            (reporters[i], reporterKeys[i]) = makeAddrAndKey(string.concat("reporter-", group));

            vm.startPrank(owner);
            sources[i].setAsset(COL_ASSET, true, 1);
            sources[i].setAsset(LOAN_ASSET, true, 1);
            sources[i].setReporter(reporters[i], true);
            sources[i].setReporterAuthorisation(reporters[i], COL_ASSET, true);
            sources[i].setReporterAuthorisation(reporters[i], LOAN_ASSET, true);
            vm.stopPrank();
        }

        _commitRoute(COL_ASSET, routeSources);
        _commitRoute(LOAN_ASSET, routeSources);
    }

    function _commitRoute(bytes32 asset, address[] memory routeSources) internal {
        vm.prank(owner);
        governor.proposeRoute(
            asset,
            IPriceRouter.Route({
                sources: routeSources,
                minSources: 3,
                maxDeviationBps: ROUTE_DEV_BPS,
                maxStalenessSeconds: STALENESS,
                reporterHeartbeatSeconds: HEARTBEAT,
                maxSourcesPerOperatorGroup: 1
            })
        );
        vm.warp(block.timestamp + governor.ROUTE_TIMELOCK());
        governor.executeRoute(asset);
    }

    /// @dev A5.3. Whitelisting a model waits out its own timelock; revoking is immediate.
    function _whitelistIrm(address irm_) internal {
        vm.prank(owner);
        market.proposeIrm(irm_);
        vm.warp(block.timestamp + market.IRM_TIMELOCK());
        market.executeIrm(irm_);
    }

    /// @dev A6.3. Granting the pause power now waits out the full timelock, because pausing an
    ///      asset freezes liquidation in every market that uses it. Revoking stays immediate.
    function _grantGuardian(address who) internal {
        vm.prank(owner);
        governor.proposeGuardian(who);
        vm.warp(block.timestamp + governor.ROUTE_TIMELOCK());
        governor.executeGuardian(who);
    }

    // --------------------------------------------------------------------------------
    // Attestations
    // --------------------------------------------------------------------------------

    function _seedPrices(uint256 colUsd, uint256 loanUsd, uint256 depthUsd) internal {
        for (uint256 i; i < SOURCE_COUNT; ++i) {
            _attest(i, COL_ASSET, colUsd, depthUsd, block.timestamp);
            _attest(i, LOAN_ASSET, loanUsd, depthUsd, block.timestamp);
        }
    }

    /// @dev Re-publishes at `block.timestamp`, so callers must warp before re-seeding:
    ///      `AttestationSource` requires observations to move strictly forward.
    function _attest(uint256 i, bytes32 asset, uint256 price, uint256 depthUsd, uint256 observedAt) internal {
        AttestationSource.PriceAttestation memory att = AttestationSource.PriceAttestation({
            asset: asset,
            price: price,
            decimals: 18,
            observedAt: observedAt,
            depthUsd: depthUsd,
            sourceId: sources[i].SOURCE_ID()
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(reporterKeys[i], sources[i].hashAttestation(att));
        sources[i].submit(att, abi.encodePacked(r, s, v));
    }

    /// @dev Moves time forward and re-publishes everything, keeping the whole set fresh.
    function _refresh(uint256 secondsForward) internal {
        vm.warp(block.timestamp + secondsForward);
        _seedPrices(COL_PRICE_USD, LOAN_PRICE_USD, BASE_DEPTH_USD);
    }

    // --------------------------------------------------------------------------------
    // Funding and positions
    // --------------------------------------------------------------------------------

    function _fund() internal {
        loan.mint(supplier, 10_000_000 * 10 ** LOAN_DECIMALS);
        loan.mint(liquidator, 10_000_000 * 10 ** LOAN_DECIMALS);
        collateral.mint(borrower, 100_000e18);
        collateral.mint(attacker, 100_000e18);

        vm.prank(supplier);
        loan.approve(address(market), type(uint256).max);
        vm.prank(liquidator);
        loan.approve(address(market), type(uint256).max);
        vm.prank(borrower);
        collateral.approve(address(market), type(uint256).max);
        vm.prank(borrower);
        loan.approve(address(market), type(uint256).max);
        vm.prank(attacker);
        collateral.approve(address(market), type(uint256).max);
        vm.prank(attacker);
        loan.approve(address(market), type(uint256).max);
    }

    function _supply(uint256 amount) internal {
        vm.prank(supplier);
        market.supply(params, amount, 0, supplier);
    }

    function _postCollateral(address who, uint256 amount) internal {
        vm.prank(who);
        market.supplyCollateral(params, amount, who);
    }

    function _borrow(address who, uint256 amount) internal {
        vm.prank(who);
        market.borrow(params, amount, 0, who, who);
    }
}
