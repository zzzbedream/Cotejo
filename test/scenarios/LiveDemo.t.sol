// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {PriceRouter} from "../../src/PriceRouter.sol";
import {RouteGovernor} from "../../src/RouteGovernor.sol";
import {AttestationSource} from "../../src/sources/AttestationSource.sol";
import {CotejoAggregatorAdapter} from "../../src/adapters/CotejoAggregatorAdapter.sol";
import {IPriceRouter} from "../../src/interfaces/IPriceRouter.sol";
import {CotejoErrors} from "../../src/libraries/CotejoErrors.sol";

/// @notice Rehearses `script/LiveTest.s.sol` end to end against the real contracts.
///
/// @dev The demo is the deliverable that gets watched, so its sequence is pinned here rather
///      than discovered live on testnet. This exercises the same path the script takes: real
///      EIP-712 signatures, three independent `AttestationSource` instances wired into a
///      production-shaped route (`minSources = 3`, `maxDeviationBps = 200`,
///      `maxSourcesPerOperatorGroup = 1`), and the `observedAt` offset that keeps the
///      injection from being rejected as a replay before it reaches the router.
contract LiveDemoTest is Test {
    bytes32 private constant ASSET = keccak256("WBT/USD");
    string[3] private GROUPS = ["wgroup", "binance", "kraken"];

    uint256 private constant BASELINE = 100e18;
    uint256 private constant DEPTH_USD = 500_000;

    address private owner = makeAddr("owner");
    address private guardian = makeAddr("guardian");

    PriceRouter private router;
    RouteGovernor private governor;
    AttestationSource[3] private sources;
    CotejoAggregatorAdapter private adapter;

    uint256[3] private keys;
    address[3] private signers;

    function setUp() public {
        vm.warp(1_750_000_000);

        router = new PriceRouter(owner);
        governor = new RouteGovernor(address(router), owner);

        vm.prank(owner);
        router.setGovernor(address(governor));
        vm.prank(owner);
        governor.proposeGuardian(guardian);
        vm.warp(block.timestamp + governor.ROUTE_TIMELOCK());
        governor.executeGuardian(guardian);

        address[] memory routeSources = new address[](3);
        for (uint256 i; i < 3; ++i) {
            sources[i] = new AttestationSource(
                "Cotejo",
                "1",
                keccak256(bytes(string.concat("cotejo.source.", GROUPS[i]))),
                keccak256(bytes(GROUPS[i])),
                owner
            );
            routeSources[i] = address(sources[i]);

            (signers[i], keys[i]) = makeAddrAndKey(string.concat("demo-", GROUPS[i]));

            vm.startPrank(owner);
            sources[i].setAsset(ASSET, true, 250_000);
            sources[i].setReporter(signers[i], true);
            sources[i].setReporterAuthorisation(signers[i], ASSET, true);
            vm.stopPrank();
        }

        vm.prank(owner);
        governor.proposeRoute(
            ASSET,
            IPriceRouter.Route({
                sources: routeSources,
                minSources: 3,
                maxDeviationBps: 200,
                maxStalenessSeconds: 900,
                reporterHeartbeatSeconds: 300,
                maxSourcesPerOperatorGroup: 1
            })
        );
        vm.warp(block.timestamp + governor.ROUTE_TIMELOCK());
        governor.executeRoute(ASSET);

        adapter = new CotejoAggregatorAdapter(address(router), ASSET, 8, "WBT / USD");
    }

    /// @notice The demo, start to finish: agreement serves, one liar stops everything.
    function test_LiveDemo_injectionFlipsRouterToRefusing() public {
        // Step 1 — three independent operators agree.
        for (uint256 i; i < 3; ++i) {
            _attest(i, BASELINE, block.timestamp - 1);
        }

        // Step 2 — the router serves, and so does the Chainlink-shaped adapter.
        (uint256 price, uint8 decimals, uint256 observedAt) = router.latestPrice(ASSET);
        assertEq(price, BASELINE, "three agreeing sources must produce the price");
        assertEq(decimals, 18);
        assertEq(observedAt, block.timestamp - 1, "observedAt is the oldest in the set");

        (, int256 answer,,,) = adapter.latestRoundData();
        assertEq(answer, 100e8, "adapter rescales 18 decimals to the consumer's 8");

        // Step 3 — one reporter is compromised and publishes 100x.
        _attest(0, BASELINE * 100, block.timestamp);

        // Step 4 — the router refuses, with the exact figures the panel will render.
        // Sorted [100, 100, 10000]: median 100, spread 9900 -> 990_000 bps against 200.
        vm.expectRevert(
            abi.encodeWithSelector(CotejoErrors.Cotejo__DeviationExceeded.selector, ASSET, 990_000, 200)
        );
        router.latestPrice(ASSET);

        // And the refusal reaches an already-integrated consumer unchanged.
        vm.expectRevert(
            abi.encodeWithSelector(CotejoErrors.Cotejo__DeviationExceeded.selector, ASSET, 990_000, 200)
        );
        adapter.latestRoundData();
    }

    /// @dev The offset is load-bearing, not cosmetic: without it the injection never lands.
    function test_LiveDemo_injectionAtSameTimestampWouldBeRejectedAsReplay() public {
        uint256 t = block.timestamp;
        for (uint256 i; i < 3; ++i) {
            _attest(i, BASELINE, t);
        }

        AttestationSource.PriceAttestation memory att = _build(0, BASELINE * 100, t);
        bytes32 digest = sources[0].hashAttestation(att);
        bytes memory signature = _sign(0, att);

        vm.expectRevert(
            abi.encodeWithSelector(CotejoErrors.Cotejo__ReplayedAttestation.selector, ASSET, digest)
        );
        sources[0].submit(att, signature);
    }

    /// @dev The panel reads `depthUsd` per source; this pins that it survives the round trip.
    function test_LiveDemo_depthIsReadableAfterAttestation() public {
        _attest(0, BASELINE, block.timestamp - 1);

        (,,, uint256 depthUsd, address reporter,) = sources[0].latestObservation(ASSET);
        assertEq(depthUsd, DEPTH_USD, "panel must be able to show reported depth");
        assertEq(reporter, signers[0], "panel must be able to attribute the signature");
    }

    /// @dev A guardian can stop the pair outright, and the panel renders that distinctly.
    function test_LiveDemo_guardianPauseIsDistinctFromDeviation() public {
        for (uint256 i; i < 3; ++i) {
            _attest(i, BASELINE, block.timestamp - 1);
        }

        vm.prank(guardian);
        router.pause(ASSET);

        vm.expectRevert(abi.encodeWithSelector(CotejoErrors.Cotejo__Paused.selector, ASSET));
        router.latestPrice(ASSET);
    }

    // --------------------------------------------------------------------------------

    function _build(uint256 i, uint256 price, uint256 observedAt)
        private
        view
        returns (AttestationSource.PriceAttestation memory)
    {
        return AttestationSource.PriceAttestation({
            asset: ASSET,
            price: price,
            decimals: 18,
            observedAt: observedAt,
            depthUsd: DEPTH_USD,
            sourceId: sources[i].SOURCE_ID()
        });
    }

    function _sign(uint256 i, AttestationSource.PriceAttestation memory att)
        private
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(keys[i], sources[i].hashAttestation(att));
        return abi.encodePacked(r, s, v);
    }

    function _attest(uint256 i, uint256 price, uint256 observedAt) private {
        AttestationSource.PriceAttestation memory att = _build(i, price, observedAt);
        sources[i].submit(att, _sign(i, att));
    }
}
