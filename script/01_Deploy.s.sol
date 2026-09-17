// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/console2.sol";

import {CotejoState} from "./CotejoState.sol";
import {PriceRouter} from "../src/PriceRouter.sol";
import {RouteGovernor} from "../src/RouteGovernor.sol";
import {AttestationSource} from "../src/sources/AttestationSource.sol";
import {CotejoAggregatorAdapter} from "../src/adapters/CotejoAggregatorAdapter.sol";

/// @title Phase 1 — contract deployment
/// @notice Deploys every Cotejo contract, skipping anything already live on-chain.
///
/// @dev Run it as many times as the faucet forces. Each step checks whether its contract
///      already has code at the recorded address and skips it if so, which means a run that
///      dies on step 5 costs nothing to resume tomorrow.
///
///      `AggregationLib` is deliberately absent. Every one of its functions is `internal`,
///      so solc inlines them into each consumer and the library compiles to an 85-byte stub
///      that nothing links against. Deploying it would put a dead contract on the explorer
///      and spend gas for no linkage.
///
///      Order is cheapest-and-most-independent first. The three `AttestationSource`
///      instances carry no dependencies, so a failure there wastes the least. `setGovernor`
///      runs last because it is the one irreversible call in the whole phase: it can be
///      called exactly once, and after it the deployer has no power over routing, pausing,
///      or prices.
///
/// Usage:
///   forge script script/01_Deploy.s.sol:Deploy \
///     --rpc-url https://rpc.testnet.whitechain.io \
///     --account <keystore-account> \
///     --broadcast --slow \
///     --verify --verifier blockscout \
///     --verifier-url https://explorer.testnet.whitechain.io/api/
contract Deploy is CotejoState {
    function run() external {
        requireWhitechainSepolia();

        address deployer = msg.sender;
        address owner = vm.envOr("COTEJO_OWNER", deployer);

        console2.log("=== Cotejo phase 1: deploy ===");
        console2.log("  chain id            :", block.chainid);
        console2.log("  deployer            :", deployer);
        console2.log("  owner               :", owner);
        console2.log("  balance (wei)       :", deployer.balance);

        vm.startBroadcast();

        // 1-3. One AttestationSource per operator group. Independent of everything else,
        //      so they go first: a failure here is the cheapest kind.
        for (uint256 i; i < OPERATOR_GROUPS.length; ++i) {
            string memory group = OPERATOR_GROUPS[i];
            string memory key = contractKeyForGroup(group);

            if (readLive(key) != address(0)) {
                console2.log("  [skip] already live :", key);
                continue;
            }

            AttestationSource source =
                new AttestationSource("Cotejo", "1", sourceId(group), groupId(group), owner);
            writeAddress(key, address(source));
            console2.log("  [new ] AttestationSource", group, address(source));
        }

        // 4. Router.
        address routerAddr = readLive("PriceRouter");
        if (routerAddr == address(0)) {
            PriceRouter router = new PriceRouter(owner);
            routerAddr = address(router);
            writeAddress("PriceRouter", routerAddr);
            console2.log("  [new ] PriceRouter  :", routerAddr);
        } else {
            console2.log("  [skip] already live : PriceRouter");
        }

        // 5. Governor, which needs the router address.
        address governorAddr = readLive("RouteGovernor");
        if (governorAddr == address(0)) {
            RouteGovernor governor = new RouteGovernor(routerAddr, owner);
            governorAddr = address(governor);
            writeAddress("RouteGovernor", governorAddr);
            console2.log("  [new ] RouteGovernor:", governorAddr);
        } else {
            console2.log("  [skip] already live : RouteGovernor");
        }

        // 6-8. One AggregatorV3-compatible adapter per pair. Eight decimals mirrors the
        //      convention of the USD feeds consumers are already integrated against.
        for (uint256 i; i < ASSET_NAMES.length; ++i) {
            string memory name = ASSET_NAMES[i];
            string memory key = adapterKeyForAsset(name);

            if (readLive(key) != address(0)) {
                console2.log("  [skip] already live :", key);
                continue;
            }

            CotejoAggregatorAdapter adapter = new CotejoAggregatorAdapter(routerAddr, assetId(name), 8, name);
            writeAddress(key, address(adapter));
            writeAssetId(name, assetId(name));
            console2.log("  [new ] Adapter", name, address(adapter));
        }

        // 9. Bind the router to its governor. One-shot and irreversible, so it runs last:
        //    if an earlier step failed, nothing here is wasted.
        //
        //    `setGovernor` is `onlyOwner`. When the owner is a multisig rather than the
        //    deploying key — which is the arrangement this is built for — the deployer
        //    cannot make this call, and attempting it would revert the whole broadcast. In
        //    that case the script prints the call for the owner to make and carries on.
        if (PriceRouter(routerAddr).governor() != address(0)) {
            console2.log("  [skip] governor already bound");
            writeFlag("governorBound", true);
        } else if (owner == deployer) {
            PriceRouter(routerAddr).setGovernor(governorAddr);
            writeFlag("governorBound", true);
            console2.log("  [bind] governor set on router");
        } else {
            console2.log("  [MANUAL] owner is not the deployer. The owner must call:");
            console2.log("           PriceRouter", routerAddr);
            console2.log("           .setGovernor(", governorAddr, ")");
        }

        writeConfigAddress("owner", owner);

        vm.stopBroadcast();

        console2.log("=== phase 1 complete. Next: 02_Configure.s.sol ===");
    }
}
