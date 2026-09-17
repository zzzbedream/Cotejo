// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IPriceSource} from "../interfaces/IPriceSource.sol";
import {CotejoErrors} from "../libraries/CotejoErrors.sol";

/// @title TwapSource
/// @notice Skeleton for a Uniswap V3-style TWAP source. Deliberately not implemented in v1.
///
/// @dev Every read reverts with `Cotejo__TwapDisabled`. This is a placeholder for the
///      interface and the deployment story, not a working source.
///
///      Why it stays disabled, on the evidence rather than on assumption:
///
///      - The Whitechain documentation states that swaps are "not available on any testnet".
///        WhiteSwap exists as a first-party product, but not as something a contract on
///        Whitechain Sepolia can read today.
///      - A contract labelled `UniswapV3Pool` does appear on Whitechain Sepolia, at
///        0x6e057133CFa4a9Ec70c77aaFe29751460FE16307, surfacing in the explorer's own
///        indexing examples as a holder of the testnet USDW token. So a pool contract is
///        deployed. What is absent is everything that would make reading it safe: no
///        documented factory, no published pool addresses, no liquidity guarantee, and no
///        swap activity to build an observation cardinality from.
///
///      That combination is worse than having no pool at all. A TWAP over a pool with
///      negligible liquidity is not a price; it is a number an attacker sets for the cost of
///      moving a thin pool, and the time-weighting only decides how many blocks they have to
///      hold it for. Wiring this up before there is real depth would hand a route a source
///      that looks independent and is not.
///
///      TODO(v2): implement `latestPrice` once WhiteSwap, or another DEX, is live on
///      Whitechain with documented pool addresses and observable depth. The implementation
///      needs, at minimum: the pool address and its token ordering, `observe()` over a
///      configured window, a check that `observationCardinality` covers that window, a
///      minimum-liquidity floor comparable to `AttestationSource`'s `depthUsd` check, and
///      conversion from the tick's sqrt price to the route's decimals. Until all of those
///      exist, this contract reverts.
///
///      See `test/scenarios/TwapDisabled.t.sol`, which asserts the revert and records this
///      reasoning as an executable note rather than a comment nobody re-reads.
contract TwapSource is IPriceSource {
    /// @notice Pool this source would read once TWAP support lands. Informational in v1.
    address public immutable POOL;

    /// @notice Asset this source would serve once TWAP support lands. Informational in v1.
    bytes32 public immutable ASSET;

    /// @param pool_ Intended pool address. Stored but never read in v1.
    /// @param asset_ Intended asset identifier. Stored but never read in v1.
    constructor(address pool_, bytes32 asset_) {
        POOL = pool_;
        ASSET = asset_;
    }

    /// @inheritdoc IPriceSource
    /// @dev Always reverts in v1. See the contract-level note.
    function latestPrice(bytes32) external pure override returns (uint256, uint8, uint256, bytes32) {
        revert CotejoErrors.Cotejo__TwapDisabled();
    }

    /// @inheritdoc IPriceSource
    /// @dev Returns zero so that a route proposal naming this source is rejected by the
    ///      governor's `supportsAsset` check rather than silently accepted and then failing
    ///      on every read.
    function operatorGroupOf(bytes32) external pure override returns (bytes32 group) {
        return bytes32(0);
    }

    /// @inheritdoc IPriceSource
    /// @dev Always false in v1, so this source cannot be committed into a route at all.
    function supportsAsset(bytes32) external pure override returns (bool supported) {
        return false;
    }

    /// @inheritdoc IPriceSource
    /// @dev Always reverts in v1. Once implemented against a real pool, depth comes from the
    ///      reserves — the one depth figure in the system that nobody signs.
    function latestDepthUsd(bytes32) external pure override returns (uint256) {
        revert CotejoErrors.Cotejo__TwapDisabled();
    }
}
