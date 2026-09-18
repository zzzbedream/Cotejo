// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IPriceSource} from "../../src/interfaces/IPriceSource.sol";
import {CotejoErrors} from "../../src/libraries/CotejoErrors.sol";

/// @notice Configurable `IPriceSource` for tests: it can report any price, sit in any
///         operator group, revert on demand, or try to burn every drop of forwarded gas.
contract MockPriceSource is IPriceSource {
    bytes32 public asset;

    bytes32 private _group;
    uint256 private _price;
    uint8 private _decimals;
    uint256 private _observedAt;
    uint256 private _depthUsd = 1_000_000;

    /// @notice When true, every `latestPrice` call reverts. Models an unavailable source.
    bool public reverts;

    /// @notice When true, `latestPrice` spins until it runs out of the forwarded gas.
    ///         Models a source griefing the router.
    bool public gasBomb;

    /// @notice When true, only `latestDepthUsd` reverts; the price still serves.
    /// @dev A source can know a price without knowing a book. `ChainlinkCompatSource` answers
    ///      zero in that situation, but a third-party source is free to revert instead, and
    ///      the router has to treat both the same way: no depth, which propagates to a zero
    ///      borrow ceiling. Separate from `reverts`, which takes the price down too.
    bool public depthReverts;

    constructor(bytes32 asset_, bytes32 group_) {
        asset = asset_;
        _group = group_;
        _decimals = 18;
    }

    function set(uint256 price_, uint8 decimals_, uint256 observedAt_) external {
        _price = price_;
        _decimals = decimals_;
        _observedAt = observedAt_;
    }

    function setGroup(bytes32 group_) external {
        _group = group_;
    }

    function setReverts(bool reverts_) external {
        reverts = reverts_;
    }

    function setGasBomb(bool gasBomb_) external {
        gasBomb = gasBomb_;
    }

    function setDepthReverts(bool depthReverts_) external {
        depthReverts = depthReverts_;
    }

    function latestPrice(bytes32 asset_)
        external
        view
        override
        returns (uint256 price, uint8 decimals, uint256 observedAt, bytes32 group)
    {
        if (gasBomb) {
            uint256 acc;
            // Spins until the router's per-source gas cap is exhausted.
            for (uint256 i; i < type(uint256).max; ++i) {
                acc = uint256(keccak256(abi.encode(acc, i)));
            }
            return (acc, 18, block.timestamp, _group);
        }
        if (reverts) revert CotejoErrors.Cotejo__NoPrice(asset_);
        if (asset_ != asset) revert CotejoErrors.Cotejo__AssetNotSupported(asset_);
        if (_observedAt == 0) revert CotejoErrors.Cotejo__NoPrice(asset_);
        return (_price, _decimals, _observedAt, _group);
    }

    function operatorGroupOf(bytes32 asset_) external view override returns (bytes32) {
        return asset_ == asset ? _group : bytes32(0);
    }

    function supportsAsset(bytes32 asset_) external view override returns (bool) {
        return asset_ == asset;
    }

    function latestDepthUsd(bytes32 asset_) external view override returns (uint256) {
        if (reverts || depthReverts) revert CotejoErrors.Cotejo__NoPrice(asset_);
        if (asset_ != asset) revert CotejoErrors.Cotejo__AssetNotSupported(asset_);
        if (_observedAt == 0) revert CotejoErrors.Cotejo__NoPrice(asset_);
        return _depthUsd;
    }

    function setDepth(uint256 depthUsd_) external {
        _depthUsd = depthUsd_;
    }
}
