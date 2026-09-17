// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {CotejoTestBase} from "../helpers/CotejoTestBase.sol";
import {MockPriceSource} from "../helpers/MockPriceSource.sol";
import {IPriceRouter} from "../../src/interfaces/IPriceRouter.sol";
import {CotejoErrors} from "../../src/libraries/CotejoErrors.sol";

/// @notice Three sources that look independent and are not.
///
/// @dev The failure this guards against is the one that keeps happening in production: a
///      route names three separate contract addresses, passes every count-based check, and
///      is in fact one operator wearing three hats. The quorum is theatre — compromise the
///      operator and all three "independent" sources move together, deviation stays at zero,
///      and the router happily reports a manipulated price with full confidence.
///
///      On Whitechain this is not hypothetical. There is no oracle on the chain, no DEX with
///      readable liquidity on testnet, and no native stablecoin, so every price is going to
///      arrive signed from off-chain. The realistic early deployment has a small number of
///      reporters, and the realistic early mistake is standing up three feeds that all
///      terminate at the same desk.
///
///      INV-5 rejects it at proposal time, so the route never enters the 48h queue at all.
contract CircularPricingTest is CotejoTestBase {
    function test_CircularPricing() public {
        // Three distinct addresses, one operator behind all of them.
        MockPriceSource shell1 = new MockPriceSource(WBT_USD, GROUP_A);
        MockPriceSource shell2 = new MockPriceSource(WBT_USD, GROUP_A);
        MockPriceSource shell3 = new MockPriceSource(WBT_USD, GROUP_A);

        address[] memory sources = _addressArray(address(shell1), address(shell2), address(shell3));
        IPriceRouter.Route memory route = _routeWith(sources, 3, 500);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                CotejoErrors.Cotejo__OperatorConcentration.selector, WBT_USD, GROUP_A, 3, 1
            )
        );
        governor.proposeRoute(WBT_USD, route);

        // Nothing was queued, so there is no proposal to wait out and none to execute.
        (,, bool exists) = governor.getPendingRoute(WBT_USD);
        assertFalse(exists, "an unsound route must not enter the queue");
    }

    /// @dev Had the check only run at read time, the route would have sat in the queue for
    ///      48 hours looking legitimate. Confirming it is rejected outright at proposal is
    ///      the difference between a config error and a config error with a countdown.
    function test_CircularPricing_alsoRejectedWhenOnlyTwoShareAnOperator() public {
        MockPriceSource shell = new MockPriceSource(WBT_USD, GROUP_B);

        address[] memory sources = _addressArray(address(sourceB), address(shell), address(sourceC));
        IPriceRouter.Route memory route = _routeWith(sources, 2, 500);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                CotejoErrors.Cotejo__OperatorConcentration.selector, WBT_USD, GROUP_B, 2, 1
            )
        );
        governor.proposeRoute(WBT_USD, route);
    }

    /// @dev The same three addresses become a valid route the moment they are genuinely
    ///      independent, which is the point: the check is about operators, not addresses.
    function test_CircularPricing_acceptedOnceOperatorsAreDistinct() public {
        MockPriceSource shell1 = new MockPriceSource(WBT_USD, GROUP_A);
        MockPriceSource shell2 = new MockPriceSource(WBT_USD, GROUP_B);
        MockPriceSource shell3 = new MockPriceSource(WBT_USD, GROUP_C);

        address[] memory sources = _addressArray(address(shell1), address(shell2), address(shell3));
        _commitRoute(WBT_USD, _routeWith(sources, 3, 500));

        assertEq(router.getRoute(WBT_USD).sources.length, 3, "independent route should commit");
    }

    /// @dev Naming the same address twice is the cruder version of the same mistake.
    function test_CircularPricing_rejectsDuplicateSourceAddress() public {
        address[] memory sources = _addressArray(address(sourceA), address(sourceA), address(sourceB));
        IPriceRouter.Route memory route = _routeWith(sources, 2, 500);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(CotejoErrors.Cotejo__DuplicateSource.selector, address(sourceA))
        );
        governor.proposeRoute(WBT_USD, route);
    }
}
