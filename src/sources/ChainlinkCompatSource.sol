// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {IPriceSource} from "../interfaces/IPriceSource.sol";
import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";
import {CotejoErrors} from "../libraries/CotejoErrors.sol";

/// @title ChainlinkCompatSource
/// @notice Wraps an external `AggregatorV3Interface` feed so it can sit in a Cotejo route.
///
/// @dev There is no Chainlink deployment on Whitechain today — the documentation index
///      carries no oracle page at all — so this contract has nothing to point at on this
///      chain right now. It exists so that the day a real aggregator is deployed, adopting
///      it is a route change through the governor rather than a new contract and a
///      migration. Until then it is dead weight by design, and deploying it against an
///      address that is not a live aggregator simply produces a source that always reverts,
///      which the router treats as unavailable.
///
///      One aggregator, one asset. The binding is immutable, and a read for any other asset
///      reverts, so a feed for one pair can never be silently served as another.
contract ChainlinkCompatSource is IPriceSource, Ownable2Step {
    /// @notice The wrapped aggregator.
    AggregatorV3Interface public immutable AGGREGATOR;

    /// @notice The only asset this source serves.
    bytes32 public immutable ASSET;

    bytes32 private _operatorGroup;

    /// @notice The source's operator group changed.
    event OperatorGroupUpdated(bytes32 indexed previousGroup, bytes32 indexed newGroup);

    /// @param aggregator_ External AggregatorV3 feed to wrap.
    /// @param asset_ Asset identifier this feed represents.
    /// @param operatorGroup_ Operator group the feed's operator belongs to. Non-zero.
    /// @param owner_ Initial owner.
    constructor(address aggregator_, bytes32 asset_, bytes32 operatorGroup_, address owner_) Ownable(owner_) {
        if (aggregator_ == address(0) || asset_ == bytes32(0) || operatorGroup_ == bytes32(0)) {
            revert CotejoErrors.Cotejo__InvalidRouteParameter();
        }
        AGGREGATOR = AggregatorV3Interface(aggregator_);
        ASSET = asset_;
        _operatorGroup = operatorGroup_;
        emit OperatorGroupUpdated(bytes32(0), operatorGroup_);
    }

    /// @inheritdoc IPriceSource
    /// @dev Applies the checks a Chainlink consumer is expected to apply: a positive answer,
    ///      a non-zero `updatedAt`, and a round that was actually answered in its own round
    ///      rather than carried over from an earlier one. A feed failing any of them is
    ///      treated as having no price, not as having a price of zero.
    function latestPrice(bytes32 asset)
        external
        view
        override
        returns (uint256 price, uint8 decimals, uint256 observedAt, bytes32 group)
    {
        if (asset != ASSET) revert CotejoErrors.Cotejo__AssetNotSupported(asset);

        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            AGGREGATOR.latestRoundData();

        if (updatedAt == 0) revert CotejoErrors.Cotejo__NoPrice(asset);
        if (answeredInRound < roundId) revert CotejoErrors.Cotejo__NoPrice(asset);
        if (answer <= 0) revert CotejoErrors.Cotejo__ZeroPrice(asset);

        // casting to 'uint256' is safe because the check above rejected every answer at or
        // below zero, so the value is strictly positive here.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 positiveAnswer = uint256(answer);

        return (positiveAnswer, AGGREGATOR.decimals(), updatedAt, _operatorGroup);
    }

    /// @inheritdoc IPriceSource
    function operatorGroupOf(bytes32 asset) external view override returns (bytes32 group) {
        return asset == ASSET ? _operatorGroup : bytes32(0);
    }

    /// @inheritdoc IPriceSource
    function supportsAsset(bytes32 asset) external view override returns (bool supported) {
        return asset == ASSET;
    }

    /// @inheritdoc IPriceSource
    /// @dev An `AggregatorV3Interface` feed reports no market depth, and inventing one would
    ///      be worse than reporting none. Zero propagates to a zero debt ceiling, so a route
    ///      containing this source cannot back a lending market until a real depth source
    ///      exists — enforced rather than documented.
    function latestDepthUsd(bytes32 asset) external view override returns (uint256) {
        if (asset != ASSET) revert CotejoErrors.Cotejo__AssetNotSupported(asset);
        return 0;
    }

    /// @notice The source's current operator group.
    function operatorGroup() external view returns (bytes32 group) {
        return _operatorGroup;
    }

    /// @notice Changes the source's operator group. See INV-5.
    function setOperatorGroup(bytes32 newGroup) external onlyOwner {
        if (newGroup == bytes32(0)) revert CotejoErrors.Cotejo__InvalidRouteParameter();
        bytes32 previous = _operatorGroup;
        _operatorGroup = newGroup;
        emit OperatorGroupUpdated(previous, newGroup);
    }
}
