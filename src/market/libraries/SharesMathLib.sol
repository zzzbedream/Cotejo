// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {MathLib} from "./MathLib.sol";

/// @title SharesMathLib
/// @notice Conversion between assets and shares, with virtual balances and protocol-favouring
///         rounding.
///
/// @dev **Virtual shares (M4).** Every conversion adds `VIRTUAL_ASSETS` and `VIRTUAL_SHARES`
///      to the totals. This is the standard defence against the first-depositor inflation
///      attack: without it, an attacker deposits 1 wei, donates a large amount directly to the
///      contract to inflate the share price, and every subsequent depositor's shares round
///      down to zero. The virtual offset makes the initial exchange rate `1 : 1e6` and caps
///      the attacker's gain at a rounding error they paid far more than to create.
///
///      **Rounding direction.** There is exactly one rule: the protocol wins every tie.
///
///        - Supplying assets mints shares rounded *down* — the supplier gets no free share.
///        - Withdrawing assets burns shares rounded *up* — the supplier pays for the dust.
///        - Borrowing assets mints debt shares rounded *up* — the borrower owes the dust.
///        - Repaying assets burns debt shares rounded *down* — the borrower repays the dust.
///
///      In every case the rounded fraction stays with the market, and therefore with its
///      suppliers. This is pinned by `testFuzz_roundingFavoursProtocol`.
library SharesMathLib {
    using MathLib for uint256;

    /// @dev 1e6 offset. Large enough that an inflation attack costs more than it can extract,
    ///      small enough to keep share counts well inside uint128.
    uint256 internal constant VIRTUAL_SHARES = 1e6;

    /// @dev One virtual asset, so the denominator is never zero on an empty market.
    uint256 internal constant VIRTUAL_ASSETS = 1;

    function toSharesDown(uint256 assets, uint256 totalAssets, uint256 totalShares)
        internal
        pure
        returns (uint256)
    {
        return assets.mulDivDown(totalShares + VIRTUAL_SHARES, totalAssets + VIRTUAL_ASSETS);
    }

    function toAssetsDown(uint256 shares, uint256 totalAssets, uint256 totalShares)
        internal
        pure
        returns (uint256)
    {
        return shares.mulDivDown(totalAssets + VIRTUAL_ASSETS, totalShares + VIRTUAL_SHARES);
    }

    function toSharesUp(uint256 assets, uint256 totalAssets, uint256 totalShares)
        internal
        pure
        returns (uint256)
    {
        return assets.mulDivUp(totalShares + VIRTUAL_SHARES, totalAssets + VIRTUAL_ASSETS);
    }

    function toAssetsUp(uint256 shares, uint256 totalAssets, uint256 totalShares)
        internal
        pure
        returns (uint256)
    {
        return shares.mulDivUp(totalAssets + VIRTUAL_ASSETS, totalShares + VIRTUAL_SHARES);
    }
}
