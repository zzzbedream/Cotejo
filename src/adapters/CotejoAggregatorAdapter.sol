// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";
import {IPriceRouter} from "../interfaces/IPriceRouter.sol";
import {AggregationLib} from "../libraries/AggregationLib.sol";
import {CotejoErrors} from "../libraries/CotejoErrors.sol";

/// @title CotejoAggregatorAdapter
/// @notice Exposes one Cotejo asset behind the exact `AggregatorV3Interface` signature, so
///         a protocol already integrated with Chainlink can point at Cotejo without
///         changing a line.
///
/// @dev Compatibility here is about the call shape, not about pretending to be a Chainlink
///      feed. Two places where the honest answer differs from the familiar one:
///
///      `getRoundData` reverts. Cotejo computes a price on demand from live source reads and
///      keeps no round history, so there is no past round to return. Fabricating one — an
///      interpolation, a repeat of the latest answer, a zero — would be exactly the
///      stale-data failure the whole design exists to prevent. Consumers that walk
///      historical rounds will break here, loudly, which is the intended outcome.
///
///      `roundId` is derived from `observedAt` rather than counted. It is therefore
///      monotonic in time, which is what consumers actually check when they compare
///      `answeredInRound` against `roundId`, without implying that a round with that number
///      was ever stored.
contract CotejoAggregatorAdapter is AggregatorV3Interface {
    /// @notice Router the price comes from.
    IPriceRouter public immutable ROUTER;

    /// @notice Asset this adapter exposes.
    bytes32 public immutable ASSET;

    uint8 private immutable _DECIMALS;
    string private _description;

    /// @param router_ Router to read from.
    /// @param asset_ Asset identifier to expose.
    /// @param decimals_ Decimals to report prices in, e.g. 8 to mirror a USD Chainlink feed.
    /// @param description_ Human-readable pair name, e.g. "WBT / USD".
    constructor(address router_, bytes32 asset_, uint8 decimals_, string memory description_) {
        if (router_ == address(0) || asset_ == bytes32(0)) {
            revert CotejoErrors.Cotejo__InvalidRouteParameter();
        }
        if (decimals_ > AggregationLib.MAX_DECIMALS) {
            revert CotejoErrors.Cotejo__DecimalsOutOfRange(decimals_);
        }
        ROUTER = IPriceRouter(router_);
        ASSET = asset_;
        _DECIMALS = decimals_;
        _description = description_;
    }

    /// @inheritdoc AggregatorV3Interface
    function decimals() external view override returns (uint8) {
        return _DECIMALS;
    }

    /// @inheritdoc AggregatorV3Interface
    function description() external view override returns (string memory) {
        return _description;
    }

    /// @inheritdoc AggregatorV3Interface
    /// @dev Cotejo's adapter version. Unrelated to any Chainlink aggregator version.
    function version() external pure override returns (uint256) {
        return 1;
    }

    /// @inheritdoc AggregatorV3Interface
    /// @dev Always reverts. See the contract-level note.
    function getRoundData(uint80 _roundId)
        external
        pure
        override
        returns (uint80, int256, uint256, uint256, uint80)
    {
        revert CotejoErrors.Cotejo__HistoricalDataUnavailable(_roundId);
    }

    /// @inheritdoc AggregatorV3Interface
    /// @dev Propagates every router revert unchanged, so a consumer sees the specific reason
    ///      the price was refused rather than a generic failure.
    ///
    ///      `startedAt` and `updatedAt` both report the router's `observedAt`, which is the
    ///      oldest observation in the fresh set. A consumer running its own staleness check
    ///      therefore measures against the weakest source in the set, not the freshest.
    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        (uint256 price, uint8 routerDecimals, uint256 observedAt) = ROUTER.latestPrice(ASSET);

        uint256 scaled = AggregationLib.normalize(price, routerDecimals, _DECIMALS);
        if (scaled > uint256(type(int256).max)) {
            revert CotejoErrors.Cotejo__PriceOverflowsInt256(scaled);
        }

        // casting to 'uint80' is safe because observedAt is a unix timestamp (~1.7e9) and
        // type(uint80).max is ~1.2e24 — roughly 38 trillion years of headroom.
        // forge-lint: disable-next-line(unsafe-typecast)
        roundId = uint80(observedAt);

        // casting to 'int256' is safe because the bound above rejected anything above
        // type(int256).max, which is the only way this cast could go negative.
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 answerOut = int256(scaled);

        return (roundId, answerOut, observedAt, observedAt, roundId);
    }
}
