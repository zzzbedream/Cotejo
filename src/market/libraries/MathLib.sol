// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title MathLib
/// @notice Fixed-point helpers. Every rounding direction here is a deliberate choice, and the
///         choice is always the one that favours the protocol over the caller.
library MathLib {
    uint256 internal constant WAD = 1e18;

    function mulDivDown(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return (x * y) / d;
    }

    function mulDivUp(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return (x * y + (d - 1)) / d;
    }

    function wMulDown(uint256 x, uint256 y) internal pure returns (uint256) {
        return mulDivDown(x, y, WAD);
    }

    function wDivDown(uint256 x, uint256 y) internal pure returns (uint256) {
        return mulDivDown(x, WAD, y);
    }

    function wDivUp(uint256 x, uint256 y) internal pure returns (uint256) {
        return mulDivUp(x, WAD, y);
    }

    function min(uint256 x, uint256 y) internal pure returns (uint256) {
        return x < y ? x : y;
    }

    function zeroFloorSub(uint256 x, uint256 y) internal pure returns (uint256) {
        return x > y ? x - y : 0;
    }

    /// @notice Third-order Taylor approximation of `(1 + rate)^n - 1`, compounded per second.
    /// @dev Cheaper than exponentiation and always *under*-estimates the true compounding, so
    ///      the protocol never charges more interest than genuinely accrued. Under-charging
    ///      is the safe direction here: over-charging would manufacture bad debt.
    /// @param rate Per-second rate, in WAD.
    /// @param elapsed Seconds elapsed. Seconds, never blocks (M7).
    function wTaylorCompounded(uint256 rate, uint256 elapsed) internal pure returns (uint256) {
        uint256 firstTerm = rate * elapsed;
        uint256 secondTerm = mulDivDown(firstTerm, firstTerm, 2 * WAD);
        uint256 thirdTerm = mulDivDown(secondTerm, firstTerm, 3 * WAD);
        return firstTerm + secondTerm + thirdTerm;
    }
}
