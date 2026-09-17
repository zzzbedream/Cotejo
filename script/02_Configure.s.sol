// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/console2.sol";

import {CotejoState} from "./CotejoState.sol";
import {PriceRouter} from "../src/PriceRouter.sol";
import {RouteGovernor} from "../src/RouteGovernor.sol";
import {AttestationSource} from "../src/sources/AttestationSource.sol";
import {IPriceRouter} from "../src/interfaces/IPriceRouter.sol";

/// @title Phase 2 — configure sources, guardian, and queue the routes
/// @notice Enables each asset on each source, registers reporter keys, appoints the
///         guardian, and proposes one route per pair.
///
/// @dev Ordering is forced by the contracts, not by preference. `proposeRoute` runs
///      `PriceRouter.validateRoute`, which requires every named source to answer
///      `supportsAsset(asset) == true`, so `setAsset` has to land first or the proposal
///      reverts.
///
///      The route parameters come straight from the deployment spec: `minSources = 3`,
///      `maxDeviationBps = 200`, `maxStalenessSeconds = 900`,
///      `maxSourcesPerOperatorGroup = 1`. `reporterHeartbeatSeconds` is set to 300 because
///      D2 requires `maxStalenessSeconds >= 2 * reporterHeartbeatSeconds`, and 900 against a
///      300s heartbeat leaves three heartbeats of slack.
///
///      With `minSources = 3` and one source per operator group, all three groups must be
///      reporting for any price to be produced. That is the intended posture and it means
///      the oracle refuses to answer until the full reporter set is live.
///
/// Usage:
///   forge script script/02_Configure.s.sol:Configure \
///     --rpc-url https://rpc.testnet.whitechain.io \
///     --account <keystore-account> --broadcast --slow
contract Configure is CotejoState {
    uint256 internal constant MIN_DEPTH_USD_DEFAULT = 250_000;

    function run() external {
        requireWhitechainSepolia();

        address deployer = msg.sender;
        address router = readLive("PriceRouter");
        address governor = readLive("RouteGovernor");
        require(router != address(0), "Cotejo: PriceRouter not deployed. Run 01_Deploy first.");
        require(governor != address(0), "Cotejo: RouteGovernor not deployed. Run 01_Deploy first.");
        require(
            PriceRouter(router).governor() == governor,
            "Cotejo: router is not bound to this governor. Complete step 9 of phase 1."
        );

        address guardian = vm.envOr("COTEJO_GUARDIAN", address(0));
        uint256 minDepthUsd = vm.envOr("COTEJO_MIN_DEPTH_USD", MIN_DEPTH_USD_DEFAULT);

        console2.log("=== Cotejo phase 2: configure ===");
        console2.log("  router              :", router);
        console2.log("  governor            :", governor);
        console2.log("  min depth (USD)     :", minDepthUsd);

        address[SOURCE_COUNT] memory sources = _liveSources();

        vm.startBroadcast();

        // 1. Enable every asset on every source, and register that source's reporter key.
        for (uint256 s; s < sources.length; ++s) {
            AttestationSource source = AttestationSource(sources[s]);
            string memory group = OPERATOR_GROUPS[s];
            address reporter = _reporterFor(s);

            for (uint256 a; a < ASSET_NAMES.length; ++a) {
                bytes32 asset = assetId(ASSET_NAMES[a]);

                if (!source.supportsAsset(asset)) {
                    source.setAsset(asset, true, minDepthUsd);
                    console2.log("  [asset]", group, ASSET_NAMES[a]);
                }

                if (reporter != address(0) && !source.isAuthorised(reporter, asset)) {
                    source.setReporterAuthorisation(reporter, asset, true);
                }
            }

            if (reporter != address(0) && !source.isReporter(reporter)) {
                source.setReporter(reporter, true);
                console2.log("  [reporter]", group, reporter);
            } else if (reporter == address(0)) {
                console2.log("  [WARN] no reporter key configured for group:", group);
            }
        }

        // 2. Guardian. Only it can pause, and only the governor can unpause, after 48h.
        if (guardian != address(0) && !PriceRouter(router).isGuardian(guardian)) {
            // A6.3. Granting the pause power now waits out the 48h timelock, because pausing
            // an asset freezes liquidation in every market that uses it.
            if (RouteGovernor(governor).getPendingGuardian(guardian) == 0) {
                RouteGovernor(governor).proposeGuardian(guardian);
                console2.log("  [guardian] queued, executable in 48h:", guardian);
            } else {
                console2.log("  [guardian] already queued:", guardian);
            }
            writeConfigAddress("guardian", guardian);
        } else if (guardian == address(0)) {
            console2.log("  [WARN] COTEJO_GUARDIAN unset: nobody can pause this deployment");
        }

        writeFlag("assetsEnabled", true);

        // 3. Queue one route per pair. Each starts a 48h timelock (INV-4) and is publicly
        //    readable for the whole wait.
        uint256 queued;
        for (uint256 a; a < ASSET_NAMES.length; ++a) {
            bytes32 asset = assetId(ASSET_NAMES[a]);

            (,, bool pending) = RouteGovernor(governor).getPendingRoute(asset);
            if (pending) {
                console2.log("  [skip] route already queued:", ASSET_NAMES[a]);
                continue;
            }
            if (PriceRouter(router).getRoute(asset).sources.length != 0) {
                console2.log("  [skip] route already live  :", ASSET_NAMES[a]);
                continue;
            }

            address[] memory routeSources = new address[](sources.length);
            for (uint256 s2; s2 < sources.length; ++s2) {
                routeSources[s2] = sources[s2];
            }

            RouteGovernor(governor)
                .proposeRoute(
                    asset,
                    IPriceRouter.Route({
                    sources: routeSources,
                    minSources: 3,
                    maxDeviationBps: 200,
                    // 1800/900 rather than 900/300. The heartbeat drives the keeper's gas
                    // burn, and the faucet pays 0.5 WBT per 24 hours: five sources publishing
                    // every 300s does not fit inside that, and a keeper that runs dry emits
                    // exactly the stale-price refusal this oracle exists to emit. Measure a
                    // real `submit` against the cap before lowering either figure.
                    // D2 still holds: staleness >= 2 x heartbeat.
                    maxStalenessSeconds: 1800,
                    reporterHeartbeatSeconds: 900,
                    maxSourcesPerOperatorGroup: 1
                })
                );
            ++queued;
            console2.log("  [route] queued:", ASSET_NAMES[a]);
        }

        if (queued > 0) writeFlag("routesProposed", true);

        vm.stopBroadcast();

        console2.log("  routes queued       :", queued);
        console2.log("=== phase 2 complete. Wait 48h, then run 03_ExecuteRoutes.s.sol ===");
        logBudget(gasleft(), deployer);
    }

    function _liveSources() internal view returns (address[SOURCE_COUNT] memory out) {
        for (uint256 i; i < OPERATOR_GROUPS.length; ++i) {
            out[i] = readLive(contractKeyForGroup(OPERATOR_GROUPS[i]));
            require(out[i] != address(0), "Cotejo: an AttestationSource is missing. Re-run 01_Deploy.");
        }
    }

    /// @dev Reporter keys come from the environment, one per operator group, never from a
    ///      versioned file. An unset key leaves that source with no authorised reporter,
    ///      which is safe — it simply cannot produce a price — and is reported as a warning.
    /// @dev One env var per keeper key: `COTEJO_REPORTER_1` .. `COTEJO_REPORTER_5`.
    ///
    ///      In the testnet deployment all five are derived from one operator, and that is
    ///      stated rather than obscured: operator independence is enforced by the contracts
    ///      and is **not yet real**. The names carry no venue and imply no relationship.
    function _reporterFor(uint256 index) internal view returns (address) {
        return vm.envOr(
            string.concat("COTEJO_REPORTER_", vm.toString(index + 1)), address(0)
        );
    }
}
