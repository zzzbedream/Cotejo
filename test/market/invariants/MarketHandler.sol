// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {CotejoMarket} from "../../../src/market/CotejoMarket.sol";
import {Id, MarketParams} from "../../../src/market/types/MarketTypes.sol";
import {MockERC20} from "../helpers/MockERC20.sol";
import {AttestationSource} from "../../../src/sources/AttestationSource.sol";

/// @notice Drives two markets sharing one adapter through random sequences of everything a
///         real user can do, including the oracle moving underneath them.
/// @dev Every action is allowed to fail. The invariants are about what must hold whenever one
///      succeeds, not about keeping the system in a happy state.
contract MarketHandler is CommonBase, StdUtils {
    CotejoMarket public immutable MARKET;
    MockERC20 public immutable COLLATERAL;
    MockERC20 public immutable LOAN;

    /// @dev Stored one at a time: solc cannot copy a memory struct array into storage.
    MarketParams private _pA;
    MarketParams private _pB;
    Id[2] public ids;

    address[3] public actors;
    AttestationSource[5] public sources;
    uint256[5] private _reporterKeys;

    bytes32 private constant COL_ASSET = keccak256("WBT/USD");
    bytes32 private constant LOAN_ASSET = keccak256("USDW/USD");

    uint256 public calls;

    /// @notice Times a *successful borrow* left the adapter above its depth ceiling.
    /// @dev The ceiling is a precondition on taking new debt, not a continuous property of the
    ///      book. A fall in observed liquidity legitimately leaves existing debt above it —
    ///      that is exactly what `test_DepthCapBlocksBorrowNotLiquidation` requires, since the
    ///      alternative would turn "the book got thinner" into a liquidation trigger. So the
    ///      invariant is checked at the only moment it can be violated: right after a borrow
    ///      that went through.
    uint256 public borrowCeilingViolations;

    constructor(
        CotejoMarket market_,
        MockERC20 collateral_,
        MockERC20 loan_,
        MarketParams memory paramsA_,
        MarketParams memory paramsB_,
        address[3] memory actors_,
        AttestationSource[5] memory sources_,
        uint256[5] memory keys_
    ) {
        MARKET = market_;
        COLLATERAL = collateral_;
        LOAN = loan_;
        _pA = paramsA_;
        _pB = paramsB_;
        actors = actors_;
        sources = sources_;
        _reporterKeys = keys_;
        ids[0] = _idOf(paramsA_);
        ids[1] = _idOf(paramsB_);
    }

    function supply(uint256 which, uint256 actor, uint256 amount) external {
        _run(which, actor, abi.encodeCall(MARKET.supply, (_p(which), _amt(amount, 1e12), 0, _a(actor))));
    }

    function withdraw(uint256 which, uint256 actor, uint256 amount) external {
        _run(
            which,
            actor,
            abi.encodeCall(MARKET.withdraw, (_p(which), _amt(amount, 1e11), 0, _a(actor), _a(actor)))
        );
    }

    function supplyCollateral(uint256 which, uint256 actor, uint256 amount) external {
        _run(
            which, actor, abi.encodeCall(MARKET.supplyCollateral, (_p(which), _amt(amount, 1e21), _a(actor)))
        );
    }

    function withdrawCollateral(uint256 which, uint256 actor, uint256 amount) external {
        _run(
            which,
            actor,
            abi.encodeCall(MARKET.withdrawCollateral, (_p(which), _amt(amount, 1e20), _a(actor), _a(actor)))
        );
    }

    function borrow(uint256 which, uint256 actor, uint256 amount) external {
        MarketParams memory p = _p(which);

        vm.prank(_a(actor));
        (bool ok,) = address(MARKET)
            .call(abi.encodeCall(MARKET.borrow, (p, _amt(amount, 1e11), 0, _a(actor), _a(actor))));
        ++calls;

        if (ok) {
            try MARKET.maxTotalBorrow(p) returns (uint256 cap) {
                if (MARKET.adapterTotalBorrow(p.oracleAdapter) > cap) ++borrowCeilingViolations;
            } catch {
                // A borrow that succeeded cannot leave the oracle unreadable, but if it did
                // there is no ceiling to compare against.
            }
        }
    }

    function repay(uint256 which, uint256 actor, uint256 amount) external {
        _run(which, actor, abi.encodeCall(MARKET.repay, (_p(which), _amt(amount, 1e10), 0, _a(actor))));
    }

    function liquidate(uint256 which, uint256 actor, uint256 target, uint256 seize) external {
        _run(which, actor, abi.encodeCall(MARKET.liquidate, (_p(which), _a(target), _amt(seize, 1e20), 0)));
    }

    function poke(uint256 which) external {
        uint256 w = bound(which, 0, 1);
        (bool ok,) = address(MARKET).call(abi.encodeCall(MARKET.pokeDepthAnchor, (_p(w))));
        (ok,) = address(MARKET).call(abi.encodeCall(MARKET.pokeOracleState, (_p(w))));
        ok;
        ++calls;
    }

    /// @notice Time passes and every reporter republishes, sometimes at a different price.
    function drift(uint256 secondsForward, uint256 priceSeed, uint256 depthSeed) external {
        vm.warp(block.timestamp + bound(secondsForward, 1, 600));
        uint256 colPrice = bound(priceSeed, 40e18, 250e18);
        uint256 depth = bound(depthSeed, 100_000, 20_000_000);

        for (uint256 i; i < 5; ++i) {
            _attest(i, COL_ASSET, colPrice, depth);
            _attest(i, LOAN_ASSET, 1e18, depth);
        }
        ++calls;
    }

    // --------------------------------------------------------------------------------

    function _run(uint256 which, uint256 actor, bytes memory data) private {
        vm.prank(_a(actor));
        (bool ok,) = address(MARKET).call(data);
        ok; // failures are expected and are not the subject of the invariants
        which;
        ++calls;
    }

    function _p(uint256 which) private view returns (MarketParams memory) {
        return bound(which, 0, 1) == 0 ? _pA : _pB;
    }

    function _a(uint256 actor) private view returns (address) {
        return actors[bound(actor, 0, 2)];
    }

    function _amt(uint256 raw, uint256 ceiling) private pure returns (uint256) {
        return bound(raw, 1, ceiling);
    }

    function _attest(uint256 i, bytes32 asset, uint256 price, uint256 depthUsd) private {
        AttestationSource.PriceAttestation memory att = AttestationSource.PriceAttestation({
            asset: asset,
            price: price,
            decimals: 18,
            observedAt: block.timestamp,
            depthUsd: depthUsd,
            sourceId: sources[i].SOURCE_ID()
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_reporterKeys[i], sources[i].hashAttestation(att));
        try sources[i].submit(att, abi.encodePacked(r, s, v)) {} catch {}
    }

    function _idOf(MarketParams memory p) private pure returns (Id) {
        return Id.wrap(keccak256(abi.encode(p)));
    }
}
