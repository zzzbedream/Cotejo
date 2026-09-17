// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

/// @title CotejoState
/// @notice Shared deployment state, persisted to `deployments/<chainid>.json`.
///
/// @dev Resumability is the whole point of this file. The faucet pays out 0.5 WBT per 24
///      hours, so a deployment that dies halfway has to pick up the next day rather than
///      start over.
///
///      The rule that makes it safe: an address recorded in the JSON is only trusted when
///      that address still has code on-chain. A run that records an address and then fails
///      before the transaction lands leaves a stale entry; the next run sees `code.length
///      == 0` and redeploys. So the JSON is a cache, never the source of truth — the chain
///      is.
abstract contract CotejoState is Script {
    string internal constant STATE_DIR = "deployments/";

    /// @notice How many AttestationSource contracts this deployment stands up, one per
    ///         operator group.
    /// @dev Declared as a constant, not written as a literal at each use site, because it was
    ///      previously a literal: `OPERATOR_GROUPS` grew from three entries to five and
    ///      `LiveTest.s.sol` kept an `address[3]`. That combination compiles — the loop bound
    ///      comes from the string array and the index bound from the address array — and fails
    ///      at run time with an out-of-bounds panic, on chain, mid-broadcast.
    uint256 internal constant SOURCE_COUNT = 5;

    /// @notice How many asset pairs this deployment serves.
    uint256 internal constant ASSET_COUNT = 1;

    /// @notice Assets this deployment serves, in a fixed order.
    /// @dev One pair for the testnet deployment. Three pairs at a 900s heartbeat across five
    ///      sources does not fit the faucet's 0.5 WBT per 24 hours, and a keeper that runs out
    ///      of gas produces exactly the stale-price refusal this oracle is built to emit —
    ///      correct behaviour, indistinguishable from a broken deployment to anyone watching.
    string[ASSET_COUNT] internal ASSET_NAMES = ["WBT/USD"];

    /// @notice Operator groups, one AttestationSource per group (INV-5).
    ///
    /// @dev **These names go on-chain as operator identities and must be true.**
    ///
    ///      They were previously `["wgroup", "binance", "kraken"]`, which would have written
    ///      `keccak256("binance")` and `keccak256("kraken")` to a public chain as the operators
    ///      behind keys this deployment controls, and `wgroup` implies a WhiteBIT relationship
    ///      that does not exist. The field is called `operatorGroup`, not `dataSource`: three
    ///      price feeds pulled by one process are one operator, however many venues they read.
    ///
    ///      Five, not three. `minSources = 3` over exactly three sources leaves no redundancy,
    ///      so a single keeper stumble blanks the feed. Five also pre-positions the route to
    ///      satisfy the lending market's R7 (`minSources + 2`) without a later route change.
    string[SOURCE_COUNT] internal OPERATOR_GROUPS =
        ["cotejo-keeper-1", "cotejo-keeper-2", "cotejo-keeper-3", "cotejo-keeper-4", "cotejo-keeper-5"];

    function statePath() internal view returns (string memory) {
        return string.concat(STATE_DIR, vm.toString(block.chainid), ".json");
    }

    // --------------------------------------------------------------------------------
    // Reads
    // --------------------------------------------------------------------------------

    /// @notice Address recorded at `key`, or the zero address when absent or unparseable.
    function readAddress(string memory key) internal view returns (address) {
        string memory json = vm.readFile(statePath());
        string memory path = string.concat(".contracts.", key);
        try vm.parseJsonAddress(json, path) returns (address a) {
            return a;
        } catch {
            return address(0);
        }
    }

    /// @notice A recorded address that still has code on-chain, or zero.
    /// @dev This is the check that makes a resumed run correct rather than merely fast.
    function readLive(string memory key) internal view returns (address) {
        address recorded = readAddress(key);
        if (recorded == address(0)) return address(0);
        if (recorded.code.length == 0) return address(0);
        return recorded;
    }

    function readFlag(string memory key) internal view returns (bool) {
        string memory json = vm.readFile(statePath());
        try vm.parseJsonBool(json, string.concat(".config.", key)) returns (bool b) {
            return b;
        } catch {
            return false;
        }
    }

    function readConfigAddress(string memory key) internal view returns (address) {
        string memory json = vm.readFile(statePath());
        try vm.parseJsonAddress(json, string.concat(".config.", key)) returns (address a) {
            return a;
        } catch {
            return address(0);
        }
    }

    // --------------------------------------------------------------------------------
    // Writes
    // --------------------------------------------------------------------------------

    function writeAddress(string memory key, address value) internal {
        vm.writeJson(vm.toString(value), statePath(), string.concat(".contracts.", key));
    }

    function writeFlag(string memory key, bool value) internal {
        vm.writeJson(value ? "true" : "false", statePath(), string.concat(".config.", key));
    }

    function writeConfigAddress(string memory key, address value) internal {
        vm.writeJson(vm.toString(value), statePath(), string.concat(".config.", key));
    }

    function writeAssetId(string memory name, bytes32 id) internal {
        vm.writeJson(vm.toString(id), statePath(), string.concat(".assets.", '["', name, '"]'));
    }

    // --------------------------------------------------------------------------------
    // Identifiers
    // --------------------------------------------------------------------------------

    /// @notice Asset identifier as the contracts expect it.
    function assetId(string memory name) internal pure returns (bytes32) {
        return keccak256(bytes(name));
    }

    /// @notice Operator group identifier.
    function groupId(string memory group) internal pure returns (bytes32) {
        return keccak256(bytes(group));
    }

    /// @notice Source identifier bound into every attestation for that source.
    function sourceId(string memory group) internal pure returns (bytes32) {
        return keccak256(bytes(string.concat("cotejo.source.", group)));
    }

    function contractKeyForGroup(string memory group) internal pure returns (string memory) {
        return string.concat("AttestationSource_", group);
    }

    function adapterKeyForAsset(string memory name) internal pure returns (string memory) {
        // "WBT/USD" -> "Adapter_WBT_USD"
        bytes memory b = bytes(name);
        bytes memory out = new bytes(b.length);
        for (uint256 i; i < b.length; ++i) {
            // casting to 'bytes1' is safe because "_" is a one-byte literal, not a
            // truncation of a wider value.
            // forge-lint: disable-next-line(unsafe-typecast)
            out[i] = b[i] == "/" ? bytes1("_") : b[i];
        }
        return string.concat("Adapter_", string(out));
    }

    // --------------------------------------------------------------------------------
    // Guards
    // --------------------------------------------------------------------------------

    /// @notice Aborts unless the RPC is actually Whitechain Sepolia.
    /// @dev viem and other tooling ship two similarly named Whitechain networks —
    ///      `whitechainSepolia` (1874) and `whitechainTestnet` (2625) — and the docs warn
    ///      they are different chains. Deploying against the wrong one would look like a
    ///      success and produce addresses nobody can use, so this is checked rather than
    ///      assumed.
    function requireWhitechainSepolia() internal view {
        require(block.chainid == 1874, "Cotejo: not Whitechain Sepolia (expected chain id 1874)");
    }

    function logBudget(uint256 startGas, address sender) internal view {
        uint256 balance = sender.balance;
        console2.log("  deployer            :", sender);
        console2.log("  balance (wei)       :", balance);
        console2.log("  gas used so far     :", startGas - gasleft());
    }
}
