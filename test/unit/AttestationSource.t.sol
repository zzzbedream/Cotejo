// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {AttestationSource} from "../../src/sources/AttestationSource.sol";
import {CotejoErrors} from "../../src/libraries/CotejoErrors.sol";

/// @notice Unit tests for the signed-attestation intake path.
contract AttestationSourceTest is Test {
    bytes32 private constant WBT_USD = keccak256("WBT/USD");
    bytes32 private constant OTHER_ASSET = keccak256("ETH/USD");
    bytes32 private constant SOURCE_ID = keccak256("cotejo.source.primary");
    bytes32 private constant GROUP_A = keccak256("operator.a");
    bytes32 private constant GROUP_B = keccak256("operator.b");

    uint256 private constant MIN_DEPTH = 50_000;

    AttestationSource private source;

    address private owner = makeAddr("owner");
    address private reporter;
    uint256 private reporterKey;
    address private outsider;
    uint256 private outsiderKey;

    function setUp() public {
        vm.warp(1_750_000_000);
        (reporter, reporterKey) = makeAddrAndKey("reporter");
        (outsider, outsiderKey) = makeAddrAndKey("outsider");

        source = new AttestationSource("Cotejo", "1", SOURCE_ID, GROUP_A, owner);

        vm.startPrank(owner);
        source.setAsset(WBT_USD, true, MIN_DEPTH);
        source.setReporter(reporter, true);
        source.setReporterAuthorisation(reporter, WBT_USD, true);
        vm.stopPrank();
    }

    // --------------------------------------------------------------------------------
    // Happy path
    // --------------------------------------------------------------------------------

    function test_acceptsSignedAttestationAndServesIt() public {
        _submit(_attestation(100e18, 18, block.timestamp, MIN_DEPTH), reporterKey);

        (uint256 price, uint8 decimals, uint256 observedAt, bytes32 group) = source.latestPrice(WBT_USD);

        assertEq(price, 100e18);
        assertEq(decimals, 18);
        assertEq(observedAt, block.timestamp);
        assertEq(group, GROUP_A);
    }

    function test_anyoneMayRelayAReportersAttestation() public {
        AttestationSource.PriceAttestation memory att = _attestation(100e18, 18, block.timestamp, MIN_DEPTH);
        bytes memory signature = _sign(att, reporterKey);

        // The signature authorises the write, not the caller.
        vm.prank(makeAddr("relayer"));
        source.submit(att, signature);

        (uint256 price,,,) = source.latestPrice(WBT_USD);
        assertEq(price, 100e18);
    }

    function test_acceptsHeterogeneousDecimals() public {
        // USDW on Whitechain Sepolia carries 6 decimals.
        _submit(_attestation(1_500_000, 6, block.timestamp, MIN_DEPTH), reporterKey);

        (uint256 price, uint8 decimals,,) = source.latestPrice(WBT_USD);
        assertEq(price, 1_500_000);
        assertEq(decimals, 6);
    }

    // --------------------------------------------------------------------------------
    // Rejections
    // --------------------------------------------------------------------------------

    function test_rejectsObservationInTheFuture() public {
        uint256 future = block.timestamp + 1;
        AttestationSource.PriceAttestation memory att = _attestation(100e18, 18, future, MIN_DEPTH);

        bytes memory signature = _sign(att, reporterKey);
        vm.expectRevert(
            abi.encodeWithSelector(CotejoErrors.Cotejo__FutureObservation.selector, future, block.timestamp)
        );
        source.submit(att, signature);
    }

    function test_rejectsExactReplay() public {
        AttestationSource.PriceAttestation memory att = _attestation(100e18, 18, block.timestamp, MIN_DEPTH);
        bytes memory signature = _sign(att, reporterKey);

        source.submit(att, signature);

        bytes32 digest = source.hashAttestation(att);
        vm.expectRevert(
            abi.encodeWithSelector(CotejoErrors.Cotejo__ReplayedAttestation.selector, WBT_USD, digest)
        );
        source.submit(att, signature);
    }

    function test_rejectsObservationThatDoesNotMoveForward() public {
        uint256 t = block.timestamp;
        _submit(_attestation(100e18, 18, t, MIN_DEPTH), reporterKey);

        // A different attestation (different price, so a different digest) carrying an
        // earlier observation must not be able to walk the stored value backwards.
        AttestationSource.PriceAttestation memory older = _attestation(90e18, 18, t - 1, MIN_DEPTH);
        bytes32 digest = source.hashAttestation(older);

        bytes memory signature = _sign(older, reporterKey);
        vm.expectRevert(
            abi.encodeWithSelector(CotejoErrors.Cotejo__ReplayedAttestation.selector, WBT_USD, digest)
        );
        source.submit(older, signature);
    }

    function test_rejectsUnknownSigner() public {
        AttestationSource.PriceAttestation memory att = _attestation(100e18, 18, block.timestamp, MIN_DEPTH);

        bytes memory signature = _sign(att, outsiderKey);
        vm.expectRevert(abi.encodeWithSelector(CotejoErrors.Cotejo__UnknownReporter.selector, outsider));
        source.submit(att, signature);
    }

    function test_rejectsReporterNotAuthorisedForAsset() public {
        vm.startPrank(owner);
        source.setAsset(OTHER_ASSET, true, 0);
        vm.stopPrank();

        AttestationSource.PriceAttestation memory att = AttestationSource.PriceAttestation({
            asset: OTHER_ASSET,
            price: 100e18,
            decimals: 18,
            observedAt: block.timestamp,
            depthUsd: MIN_DEPTH,
            sourceId: SOURCE_ID
        });

        bytes memory signature = _sign(att, reporterKey);
        vm.expectRevert(
            abi.encodeWithSelector(CotejoErrors.Cotejo__ReporterNotAuthorised.selector, reporter, OTHER_ASSET)
        );
        source.submit(att, signature);
    }

    function test_rejectsAttestationForAnotherSource() public {
        AttestationSource.PriceAttestation memory att = _attestation(100e18, 18, block.timestamp, MIN_DEPTH);
        att.sourceId = keccak256("some.other.source");

        bytes memory signature = _sign(att, reporterKey);
        vm.expectRevert(abi.encodeWithSelector(CotejoErrors.Cotejo__AssetNotSupported.selector, WBT_USD));
        source.submit(att, signature);
    }

    function test_rejectsDisabledAsset() public {
        vm.prank(owner);
        source.setAsset(WBT_USD, false, 0);

        AttestationSource.PriceAttestation memory att = _attestation(100e18, 18, block.timestamp, MIN_DEPTH);

        bytes memory signature = _sign(att, reporterKey);
        vm.expectRevert(abi.encodeWithSelector(CotejoErrors.Cotejo__AssetNotSupported.selector, WBT_USD));
        source.submit(att, signature);
    }

    function test_rejectsZeroPrice() public {
        AttestationSource.PriceAttestation memory att = _attestation(0, 18, block.timestamp, MIN_DEPTH);

        bytes memory signature = _sign(att, reporterKey);
        vm.expectRevert(abi.encodeWithSelector(CotejoErrors.Cotejo__ZeroPrice.selector, WBT_USD));
        source.submit(att, signature);
    }

    function test_rejectsInsufficientDepth() public {
        AttestationSource.PriceAttestation memory att =
            _attestation(100e18, 18, block.timestamp, MIN_DEPTH - 1);

        bytes memory signature = _sign(att, reporterKey);
        vm.expectRevert(
            abi.encodeWithSelector(CotejoErrors.Cotejo__InsufficientDepth.selector, MIN_DEPTH - 1, MIN_DEPTH)
        );
        source.submit(att, signature);
    }

    function test_rejectsRevokedReporter() public {
        vm.prank(owner);
        source.setReporter(reporter, false);

        AttestationSource.PriceAttestation memory att = _attestation(100e18, 18, block.timestamp, MIN_DEPTH);

        bytes memory signature = _sign(att, reporterKey);
        vm.expectRevert(abi.encodeWithSelector(CotejoErrors.Cotejo__UnknownReporter.selector, reporter));
        source.submit(att, signature);
    }

    // --------------------------------------------------------------------------------
    // Read path
    // --------------------------------------------------------------------------------

    function test_latestObservationExposesDepthAndReporter() public {
        _submit(_attestation(100e18, 18, block.timestamp, MIN_DEPTH + 7), reporterKey);

        (uint256 price, uint8 decimals, uint256 observedAt, uint256 depthUsd, address who, bytes32 group) =
            source.latestObservation(WBT_USD);

        assertEq(price, 100e18);
        assertEq(decimals, 18);
        assertEq(observedAt, block.timestamp);
        assertEq(depthUsd, MIN_DEPTH + 7, "depth must be auditable on-chain, not just signed");
        assertEq(who, reporter, "the signing key must be attributable");
        assertEq(group, GROUP_A);
    }

    function test_latestObservationRevertsBeforeAnyAttestation() public {
        vm.expectRevert(abi.encodeWithSelector(CotejoErrors.Cotejo__NoPrice.selector, WBT_USD));
        source.latestObservation(WBT_USD);
    }

    function test_latestObservationRevertsForUnsupportedAsset() public {
        vm.expectRevert(abi.encodeWithSelector(CotejoErrors.Cotejo__AssetNotSupported.selector, OTHER_ASSET));
        source.latestObservation(OTHER_ASSET);
    }

    function test_latestPriceRevertsBeforeAnyAttestation() public {
        vm.expectRevert(abi.encodeWithSelector(CotejoErrors.Cotejo__NoPrice.selector, WBT_USD));
        source.latestPrice(WBT_USD);
    }

    function test_latestPriceRevertsForUnsupportedAsset() public {
        vm.expectRevert(abi.encodeWithSelector(CotejoErrors.Cotejo__AssetNotSupported.selector, OTHER_ASSET));
        source.latestPrice(OTHER_ASSET);
    }

    /// @dev The read that makes proposal-time INV-5 enforcement possible: the group is
    ///      available before any attestation exists.
    function test_operatorGroupIsReadableBeforeAnyAttestation() public view {
        assertEq(source.operatorGroupOf(WBT_USD), GROUP_A);
        assertEq(source.operatorGroupOf(OTHER_ASSET), bytes32(0));
        assertTrue(source.supportsAsset(WBT_USD));
        assertFalse(source.supportsAsset(OTHER_ASSET));
    }

    function test_operatorGroupCanChangeAfterDeployment() public {
        vm.prank(owner);
        source.setOperatorGroup(GROUP_B);

        assertEq(source.operatorGroup(), GROUP_B);
        assertEq(source.operatorGroupOf(WBT_USD), GROUP_B);
    }

    function test_viewHelpersReportRegistrationState() public view {
        assertTrue(source.isReporter(reporter));
        assertFalse(source.isReporter(outsider));
        assertTrue(source.isAuthorised(reporter, WBT_USD));
        assertFalse(source.isAuthorised(outsider, WBT_USD));
        assertEq(source.minDepthUsd(WBT_USD), MIN_DEPTH);
        assertFalse(source.isConsumed(bytes32(0)));
    }

    function test_consumedDigestIsRecorded() public {
        AttestationSource.PriceAttestation memory att = _attestation(100e18, 18, block.timestamp, MIN_DEPTH);
        bytes32 digest = source.hashAttestation(att);

        assertFalse(source.isConsumed(digest));
        source.submit(att, _sign(att, reporterKey));
        assertTrue(source.isConsumed(digest));
    }

    // --------------------------------------------------------------------------------
    // Administration
    // --------------------------------------------------------------------------------

    function test_onlyOwnerMayAdminister() public {
        vm.startPrank(outsider);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider));
        source.setAsset(WBT_USD, true, 0);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider));
        source.setReporter(outsider, true);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider));
        source.setReporterAuthorisation(outsider, WBT_USD, true);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider));
        source.setOperatorGroup(GROUP_B);

        vm.stopPrank();
    }

    function test_rejectsZeroValuedConfiguration() public {
        vm.startPrank(owner);

        vm.expectRevert(CotejoErrors.Cotejo__InvalidRouteParameter.selector);
        source.setOperatorGroup(bytes32(0));

        vm.expectRevert(abi.encodeWithSelector(CotejoErrors.Cotejo__UnknownReporter.selector, address(0)));
        source.setReporter(address(0), true);

        vm.stopPrank();
    }

    function test_constructorRejectsZeroIdentifiers() public {
        vm.expectRevert(CotejoErrors.Cotejo__InvalidRouteParameter.selector);
        new AttestationSource("Cotejo", "1", bytes32(0), GROUP_A, owner);

        vm.expectRevert(CotejoErrors.Cotejo__InvalidRouteParameter.selector);
        new AttestationSource("Cotejo", "1", SOURCE_ID, bytes32(0), owner);
    }

    // --------------------------------------------------------------------------------
    // Helpers
    // --------------------------------------------------------------------------------

    // --------------------------------------------------------------------------------
    // Gas budget
    // --------------------------------------------------------------------------------

    /// @notice A steady-state `submit` must be cheap enough that the whole deployment's
    ///         heartbeat fits inside the faucet's daily payout.
    ///
    /// @dev The heartbeat was set to 900s from an unverified ~70k gas estimate. This is the
    ///      measurement that estimate stood in for, kept as a test so that a change which
    ///      makes `submit` more expensive fails here rather than silently draining the keeper
    ///      at 03:00 and producing a stale-price refusal that looks like a broken deployment.
    ///
    ///      Steady state, not first write: the first attestation for an asset pays
    ///      zero-to-nonzero SSTORE on every slot it touches, which happens once per source per
    ///      asset and never again. The warm-up submit below absorbs that.
    ///
    ///      **This measures L2 execution gas only.** Whitechain Sepolia is an OP Stack chain
    ///      and also charges an L1 data fee per transaction, which no local test can observe.
    ///      The assertion therefore claims only half the faucet, leaving the rest for the L1
    ///      component, the deployment itself and the configuration transactions. The real
    ///      figure has to come off a broadcast receipt before anyone relies on it.
    function test_steadyStateSubmitFitsTheFaucetBudget() public {
        // Deployment shape, mirroring script/CotejoState.sol.
        uint256 sourceCount = 5;
        uint256 assetCount = 1;
        uint256 heartbeatSeconds = 900;

        // Whitechain Sepolia: 5 gwei minimum base fee, faucet pays 0.5 WBT per 24 hours.
        uint256 minBaseFeeWei = 5 gwei;
        uint256 faucetPerDayWei = 0.5 ether;

        // Warm-up: pays the one-time cold-slot cost so the measurement below is steady state.
        _submit(_attestation(100e18, 18, block.timestamp, MIN_DEPTH), reporterKey);

        vm.warp(block.timestamp + heartbeatSeconds);
        AttestationSource.PriceAttestation memory att = _attestation(101e18, 18, block.timestamp, MIN_DEPTH);
        bytes memory signature = _sign(att, reporterKey);

        uint256 before = gasleft();
        source.submit(att, signature);
        uint256 executionGas = before - gasleft();

        // A test call is not a transaction: add what the EVM charges before execution starts.
        // 21,000 intrinsic, plus calldata at 16 gas per non-zero byte over the whole payload
        // (selector, six ABI words, the offset and length words, and a 65-byte signature).
        // Charging every byte as non-zero overstates it, which is the safe direction.
        uint256 calldataBytes = 4 + (6 * 32) + (2 * 32) + 96;
        uint256 txGas = executionGas + 21_000 + (calldataBytes * 16);

        uint256 submitsPerDay = (1 days / heartbeatSeconds) * sourceCount * assetCount;
        uint256 costPerDayWei = submitsPerDay * txGas * minBaseFeeWei;

        emit log_named_uint("execution gas per submit ", executionGas);
        emit log_named_uint("tx gas per submit        ", txGas);
        emit log_named_uint("submits per day          ", submitsPerDay);
        emit log_named_uint("L2 cost per day (wei)    ", costPerDayWei);
        emit log_named_uint("faucet per day  (wei)    ", faucetPerDayWei);

        assertLt(
            costPerDayWei,
            faucetPerDayWei / 2,
            "heartbeat does not fit the faucet: lower the frequency or the source count"
        );
    }

    function _attestation(uint256 price, uint8 decimals, uint256 observedAt, uint256 depthUsd)
        private
        pure
        returns (AttestationSource.PriceAttestation memory)
    {
        return AttestationSource.PriceAttestation({
            asset: WBT_USD,
            price: price,
            decimals: decimals,
            observedAt: observedAt,
            depthUsd: depthUsd,
            sourceId: SOURCE_ID
        });
    }

    function _sign(AttestationSource.PriceAttestation memory att, uint256 key)
        private
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, source.hashAttestation(att));
        return abi.encodePacked(r, s, v);
    }

    function _submit(AttestationSource.PriceAttestation memory att, uint256 key) private {
        source.submit(att, _sign(att, key));
    }
}
