// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title AggregatorV3Interface
/// @notice Chainlink's AggregatorV3Interface, reproduced verbatim so Cotejo carries no
///         dependency on a Chainlink package.
/// @dev Whitechain has no Chainlink deployment, so nothing here resolves to a live feed on
///      this chain today. The interface exists for two reasons: `CotejoAggregatorAdapter`
///      implements it so existing protocols integrate without a code change, and
///      `ChainlinkCompatSource` consumes it for the day a real aggregator does exist.
interface AggregatorV3Interface {
    /// @notice Decimals the `answer` values are scaled by.
    function decimals() external view returns (uint8);

    /// @notice Human-readable description of the feed, e.g. "WBT / USD".
    function description() external view returns (string memory);

    /// @notice Version of the aggregator implementation.
    function version() external view returns (uint256);

    /// @notice Data for a specific historical round.
    /// @param _roundId Round to read.
    function getRoundData(uint80 _roundId)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    /// @notice Data for the most recent round.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
