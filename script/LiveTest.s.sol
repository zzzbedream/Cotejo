// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/console2.sol";

import {CotejoState} from "./CotejoState.sol";
import {PriceRouter} from "../src/PriceRouter.sol";
import {AttestationSource} from "../src/sources/AttestationSource.sol";
import {CotejoErrors} from "../src/libraries/CotejoErrors.sol";

/// @title Live adversarial test — the demo
/// @notice Seeds every source with the same price, proves the router serves it, then injects
///         one anomalous attestation and proves the router stops answering.
///
/// @dev This is the claim the whole system makes, executed against the real chain: a single
///      compromised reporter cannot move the published price, and the failure is loud,
///      typed, and immediate.
///
///      The demo signs its own attestations rather than waiting on the keeper, so it runs
///      standalone. That is deliberate — a demo that needs another process up is a demo that
///      does not run when you need it. The signatures are real EIP-712 signatures against the
///      deployed contracts; nothing here is mocked.
///
///      It overwrites whatever the keeper last wrote, because an `AttestationSource` holds one
///      observation per asset and the demo stamps a later `observedAt`. The keeper's next
///      heartbeat overwrites it back, so the anomaly is self-healing rather than a state the
///      deployment has to be rescued from.
///
///      Timeline inside one run: the baseline is stamped `observedAt = now - 1` and the
///      anomaly `observedAt = now`. `AttestationSource` requires observations to move
///      strictly forward, so without that offset the injection would be rejected as a replay
///      before it ever reached the router.
///
/// Keys: `COTEJO_KEEPER_MNEMONIC`, falling back to `COTEJO_DEMO_MNEMONIC`. Neither is read
///       from a versioned file, neither has a default, and both should be throwaway seeds used
///       only on testnet.
///
/// Usage:
///   export COTEJO_KEEPER_MNEMONIC="..."
///   forge script script/LiveTest.s.sol:LiveTest \
///     --rpc-url https://rpc.testnet.whitechain.io \
///     --account <keystore-account> --broadcast --slow -vv
contract LiveTest is CotejoState {
    uint256 internal constant BASELINE_PRICE = 100e18;
    uint256 internal constant ANOMALY_MULTIPLIER = 100;
    uint256 internal constant DEPTH_USD = 500_000;

    function run() external {
        requireWhitechainSepolia();

        string memory pair = vm.envOr("COTEJO_DEMO_PAIR", string("WBT/USD"));
        bytes32 asset = assetId(pair);

        address routerAddr = readLive("PriceRouter");
        require(routerAddr != address(0), "Cotejo: nothing deployed. Run 01_Deploy first.");
        PriceRouter router = PriceRouter(routerAddr);

        address[SOURCE_COUNT] memory sources;
        for (uint256 i; i < SOURCE_COUNT; ++i) {
            sources[i] = readLive(contractKeyForGroup(OPERATOR_GROUPS[i]));
            require(sources[i] != address(0), "Cotejo: an AttestationSource is missing.");
        }

        // Same seed the configuration script authorised, so the demo signs with keys
        // `AttestationSource` already accepts. `COTEJO_DEMO_MNEMONIC` stays as a fallback for a
        // run that deliberately uses a different set.
        string memory mnemonic = vm.envOr("COTEJO_KEEPER_MNEMONIC", string(""));
        if (bytes(mnemonic).length == 0) mnemonic = vm.envString("COTEJO_DEMO_MNEMONIC");
        uint256[SOURCE_COUNT] memory keys;
        address[SOURCE_COUNT] memory signers;
        for (uint256 i; i < SOURCE_COUNT; ++i) {
            // casting to 'uint32' is safe because the loop index is bounded by SOURCE_COUNT.
            // forge-lint: disable-next-line(unsafe-typecast)
            keys[i] = vm.deriveKey(mnemonic, uint32(i));
            signers[i] = vm.addr(keys[i]);
        }

        console2.log("=== Cotejo live adversarial test ===");
        console2.log("  pair                :", pair);
        console2.log("  router              :", routerAddr);

        vm.startBroadcast();

        // 0. Make sure the demo keys can attest. Idempotent; needs the source owner.
        for (uint256 i; i < SOURCE_COUNT; ++i) {
            AttestationSource s = AttestationSource(sources[i]);
            if (!s.isReporter(signers[i])) s.setReporter(signers[i], true);
            if (!s.isAuthorised(signers[i], asset)) s.setReporterAuthorisation(signers[i], asset, true);
        }

        // 1. Every operator group agreeing on the same price.
        console2.log("--- step 1: all sources agree ---");
        for (uint256 i; i < SOURCE_COUNT; ++i) {
            _attest(sources[i], keys[i], asset, BASELINE_PRICE, block.timestamp - 1);
            console2.log("  attested", OPERATOR_GROUPS[i], BASELINE_PRICE);
        }

        // 2. The router should now serve.
        _report(router, asset, "after baseline");

        // 3. One reporter is compromised and reports 100x. The rest stay honest.
        console2.log("--- step 3: inject anomaly on one source ---");
        uint256 anomalous = BASELINE_PRICE * ANOMALY_MULTIPLIER;
        _attest(sources[0], keys[0], asset, anomalous, block.timestamp);
        console2.log("  attested", OPERATOR_GROUPS[0], anomalous);

        // 4. The router must now refuse.
        _report(router, asset, "after injection");

        vm.stopBroadcast();

        console2.log("=== done. Reload the panel: the pair should read 'Protegiendo' (refusing). ===");
        console2.log("=== the keeper's next heartbeat overwrites the anomaly and it self-heals. ===");
    }

    /// @dev Signs and submits one attestation. `submit` is permissionless, so the broadcast
    ///      account relays a signature made by the demo key — which is exactly how the real
    ///      reporter fleet works.
    function _attest(address source, uint256 key, bytes32 asset, uint256 price, uint256 observedAt) internal {
        AttestationSource s = AttestationSource(source);

        AttestationSource.PriceAttestation memory att = AttestationSource.PriceAttestation({
            asset: asset,
            price: price,
            decimals: 18,
            observedAt: observedAt,
            depthUsd: DEPTH_USD,
            sourceId: s.SOURCE_ID()
        });

        (uint8 v, bytes32 r, bytes32 sig) = vm.sign(key, s.hashAttestation(att));
        s.submit(att, abi.encodePacked(r, sig, v));
    }

    /// @dev Reads the router and prints either the price or the typed refusal. The refusal is
    ///      the interesting outcome, so it is reported as a result rather than an error.
    function _report(PriceRouter router, bytes32 asset, string memory label) internal view {
        try router.latestPrice(asset) returns (uint256 price, uint8 decimals, uint256 observedAt) {
            console2.log("  [SERVING]", label);
            console2.log("    price             :", price);
            console2.log("    decimals          :", decimals);
            console2.log("    oldest observedAt :", observedAt);
        } catch (bytes memory err) {
            console2.log("  [REFUSING]", label);
            console2.log("    ", _explain(err));
        }
    }

    /// @dev Maps a revert selector to the invariant it enforces. Anything Cotejo can throw
    ///      on this path is named; anything else is surfaced as unknown rather than guessed.
    function _explain(bytes memory err) internal pure returns (string memory) {
        if (err.length < 4) return "empty revert";
        // casting to 'bytes4' is safe because the length check above guarantees at least
        // four bytes; this reads the selector, it does not truncate a number.
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes4 sel = bytes4(err);

        if (sel == CotejoErrors.Cotejo__DeviationExceeded.selector) {
            return "Cotejo__DeviationExceeded (INV-2): sources disagree beyond the route tolerance";
        }
        if (sel == CotejoErrors.Cotejo__InsufficientSources.selector) {
            return "Cotejo__InsufficientSources (INV-1): not enough fresh sources for a quorum";
        }
        if (sel == CotejoErrors.Cotejo__StalePrice.selector) {
            return "Cotejo__StalePrice (INV-3): a source answered with a stale observation";
        }
        if (sel == CotejoErrors.Cotejo__OperatorConcentration.selector) {
            return "Cotejo__OperatorConcentration (INV-5): too many sources share one operator";
        }
        if (sel == CotejoErrors.Cotejo__Paused.selector) {
            return "Cotejo__Paused (INV-6): a guardian halted this asset";
        }
        if (sel == CotejoErrors.Cotejo__RouteNotConfigured.selector) {
            return "Cotejo__RouteNotConfigured: no route installed for this asset yet";
        }
        return "unrecognised revert selector";
    }
}
