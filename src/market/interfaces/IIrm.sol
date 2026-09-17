// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {MarketParams, Market} from "../types/MarketTypes.sol";

/// @title IIrm
/// @notice Interest rate model.
/// @dev `borrowRate` is not `view` so a model can keep state, such as an adaptive curve that
///      remembers where it was. The market clamps whatever comes back to `MAX_BORROW_RATE`
///      (M5), which bounds the damage a compromised whitelist entry can do: a malicious model
///      can make borrowing expensive, it cannot drain anything.
interface IIrm {
    /// @notice Per-second borrow rate in WAD, and may update the model's own state.
    function borrowRate(MarketParams calldata marketParams, Market calldata market) external returns (uint256);

    /// @notice Per-second borrow rate in WAD, without touching state.
    function borrowRateView(MarketParams calldata marketParams, Market calldata market)
        external
        view
        returns (uint256);
}
