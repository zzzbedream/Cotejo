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
        _warnIfSeedLooksUnread();
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
                // Not a failure, but the oracle cannot ever serve a price in this state: the
                // route will install on schedule and then refuse with
                // `Cotejo__InsufficientSources`, because no key is allowed to attest.
                console2.log("  [WARN] no reporter for group, this source can never price:", group);
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
            // Worth more than a shrug: granting the pause power is itself timelocked by 48h
            // (A6.3), so every hour this stays unset is an hour added to the moment the
            // deployment first becomes pausable. It does not block anything today, and that is
            // exactly why it gets forgotten until the day it matters.
            console2.log("  [WARN] COTEJO_GUARDIAN unset: nobody can pause, and granting it costs 48h");
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
                    // burn and the faucet pays 0.5 WBT per 24 hours, so this is a budget, not
                    // a preference. Measured, not estimated: a steady-state `submit` costs
                    // 34,526 gas to execute and ~61,222 as a transaction, so five sources on
                    // one pair every 900s burns ~0.147 WBT/day at the 5 gwei floor — under a
                    // third of the faucet. The same shape at a 300s heartbeat over three pairs
                    // is ~1.3 WBT/day, which does not fit. A keeper that runs dry emits
                    // exactly the stale-price refusal this oracle exists to emit, which is
                    // correct behaviour and indistinguishable from a broken deployment.
                    // `test_steadyStateSubmitFitsTheFaucetBudget` holds that figure down.
                    // The L1 data fee an OP Stack chain adds is NOT in that number.
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

    /// @dev Foundry's `.env` parser drops a value containing spaces unless it is quoted, and
    ///      says nothing. A mnemonic is the only value here with spaces in it, so the symptom
    ///      is a seed that reads as empty while `COTEJO_GUARDIAN` on the next line — an address,
    ///      no spaces — loads fine. The run then succeeds, warns that no reporter is
    ///      configured, and looks exactly like having forgotten to set one.
    ///
    ///      This cannot tell "unset" from "unquoted", so it names both.
    function _warnIfSeedLooksUnread() internal view {
        if (bytes(vm.envOr("COTEJO_KEEPER_MNEMONIC", string(""))).length != 0) return;
        if (_reporterFor(0) != address(0)) return;
        console2.log("  [WARN] no keeper seed was read. If .env has one, check it is in quotes:");
        console2.log("         COTEJO_KEEPER_MNEMONIC=\"word word ... word\"");
    }

    /// @notice The reporter address authorised on source `index`.
    ///
    /// @dev Two ways in, checked in this order:
    ///
    ///      1. `COTEJO_REPORTER_1` .. `COTEJO_REPORTER_5`, an explicit address per group. Use
    ///         this once the five keys really are held by five operators, because then no
    ///         single seed exists that could derive them all.
    ///      2. `COTEJO_KEEPER_MNEMONIC`, from which address `index` is derived.
    ///
    ///      The second path exists because of the failure it removes. Authorisation and
    ///      signing are separate steps performed at different times: this script decides whose
    ///      signature `AttestationSource` will accept, and the keeper decides which key signs.
    ///      When those two lists are typed in by hand they can disagree, and the symptom is
    ///      not an error — it is an oracle that stays silent with everything apparently
    ///      configured, because `submit` is permissionless and a signature from an
    ///      unauthorised key is simply refused. Deriving both sides from one seed makes the
    ///      disagreement impossible to express.
    ///
    ///      An unset reporter leaves that source with no authorised key, which is safe — it
    ///      simply cannot produce a price — and is reported as a warning rather than a failure.
    ///
    ///      In this testnet deployment all five derive from one seed, and that is stated rather
    ///      than obscured: operator independence is enforced by the contracts and is **not yet
    ///      real**. The group names carry no venue and imply no relationship.
    function _reporterFor(uint256 index) internal view returns (address) {
        address explicitAddr = vm.envOr(string.concat("COTEJO_REPORTER_", vm.toString(index + 1)), address(0));
        if (explicitAddr != address(0)) return explicitAddr;

        string memory mnemonic = vm.envOr("COTEJO_KEEPER_MNEMONIC", string(""));
        if (bytes(mnemonic).length == 0) return address(0);

        // casting to 'uint32' is safe because the caller bounds index by SOURCE_COUNT.
        // forge-lint: disable-next-line(unsafe-typecast)
        return vm.addr(vm.deriveKey(mnemonic, uint32(index)));
    }
}
