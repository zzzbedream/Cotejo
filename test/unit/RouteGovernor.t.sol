// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {CotejoTestBase} from "../helpers/CotejoTestBase.sol";
import {MockPriceSource} from "../helpers/MockPriceSource.sol";
import {RouteGovernor} from "../../src/RouteGovernor.sol";
import {IPriceRouter} from "../../src/interfaces/IPriceRouter.sol";
import {CotejoErrors} from "../../src/libraries/CotejoErrors.sol";

/// @notice Unit tests for the timelock's own mechanics.
contract RouteGovernorTest is CotejoTestBase {
    function test_rejectsSecondProposalWhileOneIsQueued() public {
        vm.startPrank(owner);
        governor.proposeRoute(WBT_USD, _defaultRoute());

        vm.expectRevert(
            abi.encodeWithSelector(
                CotejoErrors.Cotejo__ProposalAlreadyQueued.selector,
                keccak256(abi.encode("cotejo.route", WBT_USD))
            )
        );
        governor.proposeRoute(WBT_USD, _defaultRoute());
        vm.stopPrank();
    }

    function test_executeRevertsWithoutAProposal() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                CotejoErrors.Cotejo__NoSuchProposal.selector, keccak256(abi.encode("cotejo.route", WBT_USD))
            )
        );
        governor.executeRoute(WBT_USD);
    }

    function test_cancelRemovesAQueuedProposal() public {
        vm.startPrank(owner);
        governor.proposeRoute(WBT_USD, _defaultRoute());
        governor.cancelRoute(WBT_USD);
        vm.stopPrank();

        (,, bool exists) = governor.getPendingRoute(WBT_USD);
        assertFalse(exists);

        vm.warp(block.timestamp + governor.ROUTE_TIMELOCK());
        vm.expectRevert();
        governor.executeRoute(WBT_USD);
    }

    function test_cancelRevertsWithoutAProposal() public {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                CotejoErrors.Cotejo__NoSuchProposal.selector, keccak256(abi.encode("cotejo.route", WBT_USD))
            )
        );
        governor.cancelRoute(WBT_USD);
    }

    function test_executionIsPermissionlessOnceMatured() public {
        vm.prank(owner);
        governor.proposeRoute(WBT_USD, _defaultRoute());

        vm.warp(block.timestamp + governor.ROUTE_TIMELOCK());

        // Anyone may push a matured proposal over the line.
        vm.prank(stranger);
        governor.executeRoute(WBT_USD);

        assertEq(router.getRoute(WBT_USD).sources.length, 3);
    }

    /// @dev A proposal that was sound when queued but has drifted during the wait must fail
    ///      to land rather than install a route that breaks INV-5 on arrival.
    function test_executionRevalidatesAndRejectsDriftedRoute() public {
        vm.prank(owner);
        governor.proposeRoute(WBT_USD, _defaultRoute());

        // During the wait, source C's operator is absorbed by source A's.
        sourceC.setGroup(GROUP_A);

        vm.warp(block.timestamp + governor.ROUTE_TIMELOCK());
        vm.expectRevert(
            abi.encodeWithSelector(
                CotejoErrors.Cotejo__OperatorConcentration.selector, WBT_USD, GROUP_A, 2, 1
            )
        );
        governor.executeRoute(WBT_USD);
    }

    function test_onlyOwnerMayProposeOrCancel() public {
        vm.startPrank(stranger);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        governor.proposeRoute(WBT_USD, _defaultRoute());

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        governor.cancelRoute(WBT_USD);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        governor.proposeUnpause(WBT_USD);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        governor.proposeGuardian(stranger);

        vm.stopPrank();
    }

    // --------------------------------------------------------------------------------
    // Unpause queue
    // --------------------------------------------------------------------------------

    function test_cannotQueueUnpauseForAnAssetThatIsNotPaused() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CotejoErrors.Cotejo__NotPaused.selector, WBT_USD));
        governor.proposeUnpause(WBT_USD);
    }

    function test_rejectsSecondUnpauseWhileOneIsQueued() public {
        vm.prank(guardian);
        router.pause(WBT_USD);

        vm.startPrank(owner);
        governor.proposeUnpause(WBT_USD);

        vm.expectRevert(
            abi.encodeWithSelector(
                CotejoErrors.Cotejo__ProposalAlreadyQueued.selector,
                keccak256(abi.encode("cotejo.unpause", WBT_USD))
            )
        );
        governor.proposeUnpause(WBT_USD);
        vm.stopPrank();
    }

    function test_cancelUnpauseLeavesTheAssetPaused() public {
        vm.prank(guardian);
        router.pause(WBT_USD);

        vm.startPrank(owner);
        governor.proposeUnpause(WBT_USD);
        governor.cancelUnpause(WBT_USD);
        vm.stopPrank();

        assertEq(governor.getPendingUnpause(WBT_USD), 0);
        assertTrue(router.isPaused(WBT_USD));
    }

    function test_cancelUnpauseRevertsWithoutAProposal() public {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                CotejoErrors.Cotejo__NoSuchProposal.selector, keccak256(abi.encode("cotejo.unpause", WBT_USD))
            )
        );
        governor.cancelUnpause(WBT_USD);
    }

    function test_executeUnpauseRevertsWithoutAProposal() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                CotejoErrors.Cotejo__NoSuchProposal.selector, keccak256(abi.encode("cotejo.unpause", WBT_USD))
            )
        );
        governor.executeUnpause(WBT_USD);
    }

    function test_pendingUnpauseEtaIsReadable() public {
        vm.prank(guardian);
        router.pause(WBT_USD);

        vm.prank(owner);
        governor.proposeUnpause(WBT_USD);

        assertEq(governor.getPendingUnpause(WBT_USD), block.timestamp + governor.ROUTE_TIMELOCK());
    }

    // --------------------------------------------------------------------------------
    // Guardians and construction
    // --------------------------------------------------------------------------------

    function test_ownerManagesGuardiansThroughTheGovernor() public {
        address second = makeAddr("guardian2");

        _grantGuardian(second);
        assertTrue(router.isGuardian(second), "granted only after the wait");

        vm.prank(owner);
        governor.removeGuardian(second);
        assertFalse(router.isGuardian(second), "revocation is immediate");
    }

    /// @notice Every guard on the guardian grant, which is the only privilege escalation in
    ///         this contract.
    ///
    /// @dev A6.3 puts the grant behind the same 48h wait as a route change, because a guardian
    ///      can pause an asset and pausing an asset freezes liquidation in every market that
    ///      reads it. The revocation stays immediate, so the timelock only ever delays gaining
    ///      power, never losing it.
    ///
    ///      All four guards had zero coverage. A timelock whose bypasses are untested is a
    ///      timelock on paper.
    function test_guardianGrantRefusesEveryMalformedPath() public {
        address candidate = makeAddr("candidate");
        bytes32 proposalId = keccak256(abi.encode("cotejo.guardian", candidate));

        // Nothing queued yet: there is nothing to execute.
        vm.expectRevert(abi.encodeWithSelector(CotejoErrors.Cotejo__NoSuchProposal.selector, proposalId));
        governor.executeGuardian(candidate);

        vm.prank(owner);
        vm.expectRevert(CotejoErrors.Cotejo__InvalidRouteParameter.selector);
        governor.proposeGuardian(address(0));

        vm.prank(owner);
        governor.proposeGuardian(candidate);
        uint64 eta = governor.getPendingGuardian(candidate);
        assertEq(eta, uint64(block.timestamp + governor.ROUTE_TIMELOCK()), "eta must be the full wait");

        // Re-proposing would otherwise be a way to keep moving the eta, or to obscure which
        // proposal is actually live.
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(CotejoErrors.Cotejo__ProposalAlreadyQueued.selector, proposalId)
        );
        governor.proposeGuardian(candidate);

        // One second short of the wait is still short of the wait.
        vm.warp(eta - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                CotejoErrors.Cotejo__TimelockNotElapsed.selector, proposalId, eta, block.timestamp
            )
        );
        governor.executeGuardian(candidate);
        assertFalse(router.isGuardian(candidate), "no power before the wait is over");

        // Execution is permissionless once the wait is over: the delay is the control, not
        // who ends it. Anyone watching the queue can finish a grant they saw coming.
        vm.warp(eta);
        vm.prank(makeAddr("bystander"));
        governor.executeGuardian(candidate);
        assertTrue(router.isGuardian(candidate), "the wait, not the caller, is the gate");
        assertEq(governor.getPendingGuardian(candidate), 0, "the proposal must be consumed");
    }

    function test_guardianProposalsAreOwnerOnly() public {
        address candidate = makeAddr("candidate2");

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        governor.proposeGuardian(candidate);

        _grantGuardian(candidate);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        governor.removeGuardian(candidate);
    }

    function test_constructorRejectsZeroRouter() public {
        vm.expectRevert(CotejoErrors.Cotejo__InvalidRouteParameter.selector);
        new RouteGovernor(address(0), owner);
    }

    function test_timelockIs48Hours() public view {
        assertEq(governor.ROUTE_TIMELOCK(), 48 hours);
        assertEq(address(governor.ROUTER()), address(router));
    }
}
