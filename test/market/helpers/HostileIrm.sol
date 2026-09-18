// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IIrm} from "../../../src/market/interfaces/IIrm.sol";
import {ICotejoMarket} from "../../../src/market/interfaces/ICotejoMarket.sol";
import {MarketParams, Market} from "../../../src/market/types/MarketTypes.sol";

/// @notice An interest rate model that always reverts.
/// @dev Models the worst case of a captured whitelist. Before the gas-capped `try/catch` this
///      froze every state-changing path — including `repay` and `liquidate` — permanently,
///      with funds inside, and de-whitelisting could not help because `irm` is part of the
///      market `Id`.
contract RevertingIrm is IIrm {
    error Hostile();

    function borrowRate(MarketParams calldata, Market calldata) external pure returns (uint256) {
        revert Hostile();
    }

    function borrowRateView(MarketParams calldata, Market calldata) external pure returns (uint256) {
        revert Hostile();
    }
}

/// @notice An interest rate model that burns every drop of gas forwarded to it.
/// @dev Without an explicit gas cap the 63/64 rule leaves the caller unable to finish, which
///      turns `try/catch` into the denial vector rather than the defence against one.
contract GasBombIrm is IIrm {
    function borrowRate(MarketParams calldata, Market calldata) external pure returns (uint256) {
        uint256 acc;
        for (uint256 i; i < type(uint256).max; ++i) {
            acc = uint256(keccak256(abi.encode(acc, i)));
        }
        return acc;
    }

    function borrowRateView(MarketParams calldata, Market calldata) external pure returns (uint256) {
        return 0;
    }
}

/// @notice An interest rate model that reenters the market mid-call.
/// @dev `borrowRate` is non-`view` and sits on every mutator, so a whitelisted model holds a
///      foothold inside `borrow` and `liquidate`, between the price read and the position
///      writes.
contract ReentrantIrm is IIrm {
    ICotejoMarket public immutable MARKET;
    MarketParams private _params;
    bool private _armed;

    constructor(address market_) {
        MARKET = ICotejoMarket(market_);
    }

    function arm(MarketParams calldata params) external {
        _params = params;
        _armed = true;
    }

    function borrowRate(MarketParams calldata, Market calldata) external returns (uint256) {
        if (_armed) {
            _armed = false;
            // Reenter. The guard makes this revert, which propagates out of `borrowRate` and
            // is absorbed by the market's `catch` — so the attempt costs the attacker the
            // interest for that interval and nothing else.
            MARKET.borrow(_params, 1, 0, address(this), address(this));
        }
        return 0;
    }

    function borrowRateView(MarketParams calldata, Market calldata) external pure returns (uint256) {
        return 0;
    }
}

/// @notice An interest rate model that returns an absurd rate instead of reverting.
/// @dev The complement to `RevertingIrm`. A model that fails loudly is caught by the
///      `try/catch`; a model that answers politely with 100% per second is not, and reaches
///      the accrual arithmetic intact. M5 is the clamp that stops it, and until this existed
///      the clamp was documented as a defence and never exercised: a captured whitelist entry
///      could not be shown to be bounded, only asserted to be.
contract HugeRateIrm is IIrm {
    uint256 public constant RATE = 1e18; // 100% per second, ~4 million times the cap.

    function borrowRate(MarketParams calldata, Market calldata) external pure returns (uint256) {
        return RATE;
    }

    function borrowRateView(MarketParams calldata, Market calldata) external pure returns (uint256) {
        return RATE;
    }
}
