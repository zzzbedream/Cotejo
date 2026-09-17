// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {IPriceRouter} from "./interfaces/IPriceRouter.sol";
import {CotejoErrors} from "./libraries/CotejoErrors.sol";

/// @title RouteGovernor
/// @notice The only address allowed to change routing on a `PriceRouter`, and the contract
///         that makes every such change wait.
///
/// @dev INV-4: a route change takes effect only after `ROUTE_TIMELOCK` has elapsed, and the
///      pending route is readable by anyone for the entire wait. A change nobody can inspect
///      before it lands is indistinguishable from a compromise, so the proposal is stored in
///      full — sources, quorum, tolerances — rather than as a hash to be revealed later.
///
///      INV-6: pausing is not symmetric with unpausing. A guardian pauses the router
///      directly and immediately, because moving towards refusing to answer needs no
///      deliberation. Lifting a pause is a route-level decision that resumes answering, so
///      it takes the full timelock here.
///
///      Execution is permissionless once the wait is over. The owner proposes and can
///      cancel, but cannot block a matured proposal by going silent, and cannot rush one by
///      being quick. `PriceRouter.commitRoute` re-validates on execution, so a proposal that
///      was sound when queued and has since drifted — a source's operator group moving, for
///      instance — fails to land instead of installing a broken route.
contract RouteGovernor is Ownable2Step {
    /// @notice How long a route change or an unpause must wait before it can execute.
    uint256 public constant ROUTE_TIMELOCK = 48 hours;

    /// @notice A queued route change, readable in full while it waits (INV-4).
    /// @param route The proposed route.
    /// @param eta Timestamp from which the proposal may be executed.
    /// @param exists Whether a proposal is queued for this asset.
    struct PendingRoute {
        IPriceRouter.Route route;
        uint64 eta;
        bool exists;
    }

    /// @notice The router this governor controls.
    IPriceRouter public immutable ROUTER;

    mapping(bytes32 asset => PendingRoute pending) private _pendingRoute;
    mapping(bytes32 asset => uint64 eta) private _pendingUnpause;
    mapping(address guardian => uint64 eta) private _pendingGuardian;

    /// @notice A route change was queued and is now publicly inspectable.
    event RouteProposed(bytes32 indexed asset, address[] sources, uint8 minSources, uint64 eta);

    /// @notice A queued route change was executed on the router.
    event RouteExecuted(bytes32 indexed asset);

    /// @notice A queued route change was cancelled before execution.
    event RouteCancelled(bytes32 indexed asset);

    /// @notice An unpause was queued (INV-6).
    event UnpauseProposed(bytes32 indexed asset, uint64 eta);

    /// @notice A queued unpause was executed.
    event UnpauseExecuted(bytes32 indexed asset);

    /// @notice A queued unpause was cancelled.
    event UnpauseCancelled(bytes32 indexed asset);

    /// @notice A guardian grant was queued (A6.3).
    event GuardianProposed(address indexed guardian, uint64 eta);

    /// @notice A queued guardian grant was executed.
    event GuardianExecuted(address indexed guardian);

    /// @notice A guardian was revoked, or a queued grant cancelled.
    event GuardianRemoved(address indexed guardian);

    /// @param router_ Router to govern.
    /// @param owner_ Proposer and canceller. Expected to be a multisig.
    constructor(address router_, address owner_) Ownable(owner_) {
        if (router_ == address(0)) revert CotejoErrors.Cotejo__InvalidRouteParameter();
        ROUTER = IPriceRouter(router_);
    }

    // --------------------------------------------------------------------------------
    // Route changes (INV-4)
    // --------------------------------------------------------------------------------

    /// @notice Queues a route change.
    /// @dev Validated against the router's own rules at proposal time, so an unsound route —
    ///      one exceeding the source cap, one whose staleness window is under two heartbeats,
    ///      or one concentrated in a single operator group — is rejected here rather than
    ///      sitting in the queue for 48h and failing on execution.
    /// @param asset Asset the route is for.
    /// @param route Proposed route.
    function proposeRoute(bytes32 asset, IPriceRouter.Route calldata route) external onlyOwner {
        bytes32 proposalId = _routeProposalId(asset);
        if (_pendingRoute[asset].exists) revert CotejoErrors.Cotejo__ProposalAlreadyQueued(proposalId);

        ROUTER.validateRoute(asset, route);

        // casting to 'uint64' is safe because block.timestamp + 48h stays far below
        // type(uint64).max; the chain would have to run for ~584 billion years first.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 eta = uint64(block.timestamp + ROUTE_TIMELOCK);
        PendingRoute storage pending = _pendingRoute[asset];
        pending.route = route;
        pending.eta = eta;
        pending.exists = true;

        emit RouteProposed(asset, route.sources, route.minSources, eta);
    }

    /// @notice Executes a matured route change. Permissionless.
    /// @param asset Asset whose queued route should be installed.
    function executeRoute(bytes32 asset) external {
        PendingRoute storage pending = _pendingRoute[asset];
        bytes32 proposalId = _routeProposalId(asset);
        if (!pending.exists) revert CotejoErrors.Cotejo__NoSuchProposal(proposalId);
        if (block.timestamp < pending.eta) {
            revert CotejoErrors.Cotejo__TimelockNotElapsed(proposalId, pending.eta, block.timestamp);
        }

        IPriceRouter.Route memory route = pending.route;
        delete _pendingRoute[asset];

        ROUTER.commitRoute(asset, route);
        emit RouteExecuted(asset);
    }

    /// @notice Cancels a queued route change.
    /// @dev No timelock: abandoning a change leaves the existing route in place, which is
    ///      the safe direction.
    /// @param asset Asset whose queued route should be discarded.
    function cancelRoute(bytes32 asset) external onlyOwner {
        if (!_pendingRoute[asset].exists) {
            revert CotejoErrors.Cotejo__NoSuchProposal(_routeProposalId(asset));
        }
        delete _pendingRoute[asset];
        emit RouteCancelled(asset);
    }

    /// @notice The queued route change for `asset`, readable throughout the wait (INV-4).
    /// @param asset Asset to inspect.
    /// @return route The proposed route.
    /// @return eta Timestamp from which it may be executed.
    /// @return exists Whether a proposal is queued at all.
    function getPendingRoute(bytes32 asset)
        external
        view
        returns (IPriceRouter.Route memory route, uint64 eta, bool exists)
    {
        PendingRoute storage pending = _pendingRoute[asset];
        return (pending.route, pending.eta, pending.exists);
    }

    // --------------------------------------------------------------------------------
    // Unpause (INV-6)
    // --------------------------------------------------------------------------------

    /// @notice Queues an unpause.
    /// @param asset Paused asset to eventually resume.
    function proposeUnpause(bytes32 asset) external onlyOwner {
        bytes32 proposalId = _unpauseProposalId(asset);
        if (_pendingUnpause[asset] != 0) revert CotejoErrors.Cotejo__ProposalAlreadyQueued(proposalId);
        if (!ROUTER.isPaused(asset)) revert CotejoErrors.Cotejo__NotPaused(asset);

        // casting to 'uint64' is safe because block.timestamp + 48h stays far below
        // type(uint64).max; the chain would have to run for ~584 billion years first.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 eta = uint64(block.timestamp + ROUTE_TIMELOCK);
        _pendingUnpause[asset] = eta;
        emit UnpauseProposed(asset, eta);
    }

    /// @notice Executes a matured unpause. Permissionless.
    /// @param asset Asset to resume.
    function executeUnpause(bytes32 asset) external {
        uint64 eta = _pendingUnpause[asset];
        bytes32 proposalId = _unpauseProposalId(asset);
        if (eta == 0) revert CotejoErrors.Cotejo__NoSuchProposal(proposalId);
        if (block.timestamp < eta) {
            revert CotejoErrors.Cotejo__TimelockNotElapsed(proposalId, eta, block.timestamp);
        }

        delete _pendingUnpause[asset];
        ROUTER.unpause(asset);
        emit UnpauseExecuted(asset);
    }

    /// @notice Cancels a queued unpause, leaving the asset paused.
    /// @param asset Asset whose queued unpause should be discarded.
    function cancelUnpause(bytes32 asset) external onlyOwner {
        if (_pendingUnpause[asset] == 0) {
            revert CotejoErrors.Cotejo__NoSuchProposal(_unpauseProposalId(asset));
        }
        delete _pendingUnpause[asset];
        emit UnpauseCancelled(asset);
    }

    /// @notice Timestamp from which a queued unpause may execute, or zero if none.
    function getPendingUnpause(bytes32 asset) external view returns (uint64 eta) {
        return _pendingUnpause[asset];
    }

    // --------------------------------------------------------------------------------
    // Guardians
    // --------------------------------------------------------------------------------

    /// @notice Queues the addition of a router guardian (A6.3).
    ///
    /// @dev **This used to be immediate, on a justification that phase 2 invalidated.** The
    ///      old reasoning was that a guardian can only pause, so granting the power could not
    ///      harm anything. That held while the router stood alone. It does not hold now:
    ///      pausing an asset makes `price()` revert, which degrades every lending market on
    ///      that asset, and a degraded market **freezes liquidation**. Freezing solvency
    ///      control is a safety event, not a liveness one.
    ///
    ///      So granting the power waits, and revoking it does not — the same asymmetry this
    ///      contract already applies to routes and to unpausing.
    /// @param guardian Address to grant the pause power to.
    function proposeGuardian(address guardian) external onlyOwner {
        if (guardian == address(0)) revert CotejoErrors.Cotejo__InvalidRouteParameter();
        bytes32 proposalId = _guardianProposalId(guardian);
        if (_pendingGuardian[guardian] != 0) {
            revert CotejoErrors.Cotejo__ProposalAlreadyQueued(proposalId);
        }

        // casting to 'uint64' is safe because block.timestamp + 48h stays far below
        // type(uint64).max; the chain would have to run for ~584 billion years first.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 eta = uint64(block.timestamp + ROUTE_TIMELOCK);
        _pendingGuardian[guardian] = eta;
        emit GuardianProposed(guardian, eta);
    }

    /// @notice Grants a matured guardian proposal. Permissionless.
    function executeGuardian(address guardian) external {
        uint64 eta = _pendingGuardian[guardian];
        bytes32 proposalId = _guardianProposalId(guardian);
        if (eta == 0) revert CotejoErrors.Cotejo__NoSuchProposal(proposalId);
        if (block.timestamp < eta) {
            revert CotejoErrors.Cotejo__TimelockNotElapsed(proposalId, eta, block.timestamp);
        }

        delete _pendingGuardian[guardian];
        ROUTER.setGuardian(guardian, true);
        emit GuardianExecuted(guardian);
    }

    /// @notice Revokes a guardian, or cancels a queued grant. Immediate.
    /// @dev Removing the ability to pause cannot freeze anything, so it takes the fast path.
    function removeGuardian(address guardian) external onlyOwner {
        delete _pendingGuardian[guardian];
        ROUTER.setGuardian(guardian, false);
        emit GuardianRemoved(guardian);
    }

    /// @notice Timestamp from which a queued guardian grant may execute, or zero if none.
    function getPendingGuardian(address guardian) external view returns (uint64 eta) {
        return _pendingGuardian[guardian];
    }

    /// @notice Binds an asset identifier to its ERC-20 on the router.
    /// @dev Not timelocked. The registry is append-only, so this can only add a mapping that
    ///      did not exist, and a mapping that did not exist cannot be load-bearing for any
    ///      market already created. Rewriting one is impossible rather than slow.
    /// @param asset Identifier, e.g. `keccak256("WBT/USD")`.
    /// @param token ERC-20 the identifier prices.
    function registerAssetToken(bytes32 asset, address token) external onlyOwner {
        ROUTER.registerAssetToken(asset, token);
    }

    // --------------------------------------------------------------------------------
    // Internal
    // --------------------------------------------------------------------------------

    function _routeProposalId(bytes32 asset) private pure returns (bytes32) {
        return keccak256(abi.encode("cotejo.route", asset));
    }

    function _unpauseProposalId(bytes32 asset) private pure returns (bytes32) {
        return keccak256(abi.encode("cotejo.unpause", asset));
    }

    function _guardianProposalId(address guardian) private pure returns (bytes32) {
        return keccak256(abi.encode("cotejo.guardian", guardian));
    }
}
