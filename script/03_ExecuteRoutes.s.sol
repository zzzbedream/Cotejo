// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/console2.sol";

import {CotejoState} from "./CotejoState.sol";
import {PriceRouter} from "../src/PriceRouter.sol";
import {RouteGovernor} from "../src/RouteGovernor.sol";
import {IPriceRouter} from "../src/interfaces/IPriceRouter.sol";

/// @title Phase 3 — execute the matured routes
/// @notice Installs each queued route once its 48h timelock has elapsed.
///
/// @dev Execution is permissionless, so this does not need the owner key — any funded
///      account can push a matured proposal over the line. That is deliberate in the
///      governor: the owner can propose and cancel, but cannot block a matured change by
///      going quiet.
///
///      `PriceRouter.commitRoute` re-validates on execution. A route that was sound when
///      queued and has drifted since — a source's operator group moving, most likely —
///      fails to land rather than installing something that breaks INV-5 on arrival. If that
///      happens, fix the source and re-propose; do not force it.
///
/// Usage:
///   forge script script/03_ExecuteRoutes.s.sol:ExecuteRoutes \
///     --rpc-url https://rpc.testnet.whitechain.io \
///     --account <keystore-account> --broadcast --slow
contract ExecuteRoutes is CotejoState {
    function run() external {
        requireWhitechainSepolia();

        address router = readLive("PriceRouter");
        address governor = readLive("RouteGovernor");
        require(router != address(0) && governor != address(0), "Cotejo: deploy phase 1 first.");

        console2.log("=== Cotejo phase 3: execute routes ===");
        console2.log("  now (unix)          :", block.timestamp);

        uint256 executed;
        uint256 waiting;

        vm.startBroadcast();

        for (uint256 a; a < ASSET_NAMES.length; ++a) {
            string memory name = ASSET_NAMES[a];
            bytes32 asset = assetId(name);

            if (PriceRouter(router).getRoute(asset).sources.length != 0) {
                console2.log("  [skip] already live :", name);
                continue;
            }

            (, uint64 eta, bool pending) = RouteGovernor(governor).getPendingRoute(asset);
            if (!pending) {
                console2.log("  [WARN] no queued route for:", name);
                continue;
            }

            if (block.timestamp < eta) {
                ++waiting;
                console2.log("  [wait]", name);
                console2.log("         seconds remaining:", eta - block.timestamp);
                continue;
            }

            RouteGovernor(governor).executeRoute(asset);
            ++executed;
            console2.log("  [live]", name);
        }

        // A6.3. The guardian grant matures on the same clock as the routes.
        address guardian = readConfigAddress("guardian");
        if (guardian != address(0) && !PriceRouter(router).isGuardian(guardian)) {
            uint64 gEta = RouteGovernor(governor).getPendingGuardian(guardian);
            if (gEta != 0 && block.timestamp >= gEta) {
                RouteGovernor(governor).executeGuardian(guardian);
                console2.log("  [guardian] granted:", guardian);
            } else if (gEta != 0) {
                console2.log("  [guardian] still waiting, seconds:", gEta - block.timestamp);
            }
        }

        if (executed > 0 && waiting == 0) writeFlag("routesExecuted", true);

        vm.stopBroadcast();

        console2.log("  executed            :", executed);
        console2.log("  still waiting       :", waiting);
        if (waiting > 0) {
            console2.log("=== re-run once the remaining timelocks elapse ===");
        } else {
            console2.log("=== deployment complete ===");
        }
    }
}
