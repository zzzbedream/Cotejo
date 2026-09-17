// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {IPriceSource} from "../interfaces/IPriceSource.sol";
import {CotejoErrors} from "../libraries/CotejoErrors.sol";

/// @title AttestationSource
/// @notice Primary Cotejo price source. Accepts EIP-712 signed price attestations from
///         registered reporters and serves the most recent one per asset.
///
/// @dev Whitechain has no deployed oracle, no testnet DEX with usable liquidity, and no
///      native stablecoin, so there is nothing on-chain to read a price from. The price has
///      to arrive from outside, signed. This contract therefore assumes the signer can lie
///      or be compromised, and does the minimum a single source can do about it: bind every
///      attestation to this contract, reject anything observed in the future, and refuse to
///      move backwards in time. Everything else — quorum, spread, staleness, operator
///      independence — is the router's job, because no single source can check those.
///
///      Operator group model. The group lives at the source, not the reporter, and is
///      mutable by the owner. Two reasons. First, `RouteGovernor` has to evaluate INV-5
///      when a route is *proposed*, which is before any attestation exists; a group derived
///      from "whoever wrote last" would read as zero at that moment and the check would be
///      unenforceable. Second, INV-5 exists precisely because a source's group can change
///      after a route is committed, so a mutable source-level group is the thing the router
///      re-reads on every price read. Reporters registered here are keys belonging to this
///      operator — several of them, so a key can be rotated without redeploying.
///
///      Reporters are EOAs. `ECDSA.recover` derives the signer from the signature, so the
///      attestation does not carry a claimed reporter address. Supporting contract signers
///      (EIP-1271) would require adding that address to the signed struct, which the agreed
///      `PriceAttestation` layout does not include.
contract AttestationSource is IPriceSource, EIP712, Ownable2Step {
    /// @notice A signed observation of one asset's price.
    /// @param asset Identifier of the asset, e.g. `keccak256("WBT/USD")`.
    /// @param price Observed price, scaled by `decimals`.
    /// @param decimals Decimals `price` is scaled by.
    /// @param observedAt Unix timestamp of observation at the origin venue.
    /// @param depthUsd Market depth behind the observation, in whole USD.
    /// @param sourceId Identifier of the source contract the attestation is meant for.
    struct PriceAttestation {
        bytes32 asset;
        uint256 price;
        uint8 decimals;
        uint256 observedAt;
        uint256 depthUsd;
        bytes32 sourceId;
    }

    /// @notice Stored latest observation for an asset.
    /// @param price Observed price, scaled by `decimals`.
    /// @param observedAt Unix timestamp of observation at the origin venue.
    /// @param depthUsd Market depth behind the observation, in whole USD.
    /// @param reporter Key that signed the attestation this record came from.
    /// @param decimals Decimals `price` is scaled by.
    struct Observation {
        uint256 price;
        uint256 observedAt;
        uint256 depthUsd;
        address reporter;
        uint8 decimals;
    }

    /// @notice EIP-712 type hash for `PriceAttestation`.
    bytes32 public constant PRICE_ATTESTATION_TYPEHASH = keccak256(
        "PriceAttestation(bytes32 asset,uint256 price,uint8 decimals,uint256 observedAt,uint256 depthUsd,bytes32 sourceId)"
    );

    /// @notice Identifier every attestation for this contract must carry.
    /// @dev The EIP-712 domain already binds a signature to this chain and this address.
    ///      `sourceId` is a second, explicit binding so an attestation signed for one
    ///      logical feed cannot be presented to another that happens to share a signer.
    bytes32 public immutable SOURCE_ID;

    bytes32 private _operatorGroup;

    mapping(address reporter => bool registered) private _isReporter;
    mapping(address reporter => mapping(bytes32 asset => bool allowed)) private _authorised;
    mapping(bytes32 asset => bool enabled) private _assetEnabled;
    mapping(bytes32 asset => uint256 minDepth) private _minDepthUsd;
    mapping(bytes32 asset => Observation obs) private _observation;
    mapping(bytes32 digest => bool used) private _consumed;

    /// @notice An attestation was accepted and is now the latest observation for the asset.
    /// @dev `depthUsd` rides along because it is the number phase 2 sizes borrow caps
    ///      against. A value that is signed but never surfaced is not checkable on-chain,
    ///      which defeats the point of signing it.
    event AttestationAccepted(
        bytes32 indexed asset,
        address indexed reporter,
        uint256 price,
        uint8 decimals,
        uint256 observedAt,
        uint256 depthUsd
    );

    /// @notice The source's operator group changed. Routes using it are re-checked on read.
    event OperatorGroupUpdated(bytes32 indexed previousGroup, bytes32 indexed newGroup);

    /// @notice A reporter was registered or removed.
    event ReporterSet(address indexed reporter, bool registered);

    /// @notice A reporter's authorisation for one asset changed.
    event ReporterAuthorisationSet(address indexed reporter, bytes32 indexed asset, bool allowed);

    /// @notice An asset was enabled or disabled on this source.
    event AssetEnabled(bytes32 indexed asset, bool enabled, uint256 minDepthUsd);

    /// @param name_ EIP-712 domain name.
    /// @param version_ EIP-712 domain version.
    /// @param sourceId_ Identifier attestations must carry to be accepted here.
    /// @param operatorGroup_ Initial operator group for this source. Must be non-zero.
    /// @param owner_ Initial owner.
    constructor(
        string memory name_,
        string memory version_,
        bytes32 sourceId_,
        bytes32 operatorGroup_,
        address owner_
    ) EIP712(name_, version_) Ownable(owner_) {
        if (sourceId_ == bytes32(0) || operatorGroup_ == bytes32(0)) {
            revert CotejoErrors.Cotejo__InvalidRouteParameter();
        }
        SOURCE_ID = sourceId_;
        _operatorGroup = operatorGroup_;
        emit OperatorGroupUpdated(bytes32(0), operatorGroup_);
    }

    // --------------------------------------------------------------------------------
    // Write path: attestation intake
    // --------------------------------------------------------------------------------

    /// @notice Submits a signed price attestation.
    /// @dev Permissionless to call: the signature, not the caller, is what authorises the
    ///      write, so anyone may relay a reporter's attestation and pay its gas.
    ///
    ///      Rejects, in order: an attestation for another source, an unsupported asset, a
    ///      zero price, an observation in the future, one already consumed, one that does
    ///      not move strictly forward in time, a signer that is not a registered reporter,
    ///      a reporter not authorised for the asset, and depth below the asset's floor.
    ///
    ///      Strict forward motion is what makes a replay useless even if the digest map
    ///      were ever cleared: re-presenting an old attestation cannot move the stored
    ///      observation backwards.
    /// @param att The attestation.
    /// @param signature EIP-712 signature over `att` by a registered reporter.
    function submit(PriceAttestation calldata att, bytes calldata signature) external {
        if (att.sourceId != SOURCE_ID) revert CotejoErrors.Cotejo__AssetNotSupported(att.asset);
        if (!_assetEnabled[att.asset]) revert CotejoErrors.Cotejo__AssetNotSupported(att.asset);
        if (att.price == 0) revert CotejoErrors.Cotejo__ZeroPrice(att.asset);
        if (att.observedAt > block.timestamp) {
            revert CotejoErrors.Cotejo__FutureObservation(att.observedAt, block.timestamp);
        }

        bytes32 digest = hashAttestation(att);
        if (_consumed[digest]) revert CotejoErrors.Cotejo__ReplayedAttestation(att.asset, digest);

        Observation memory current = _observation[att.asset];
        if (att.observedAt <= current.observedAt) {
            revert CotejoErrors.Cotejo__ReplayedAttestation(att.asset, digest);
        }

        address reporter = ECDSA.recover(digest, signature);
        if (!_isReporter[reporter]) revert CotejoErrors.Cotejo__UnknownReporter(reporter);
        if (!_authorised[reporter][att.asset]) {
            revert CotejoErrors.Cotejo__ReporterNotAuthorised(reporter, att.asset);
        }

        uint256 floor = _minDepthUsd[att.asset];
        if (att.depthUsd < floor) revert CotejoErrors.Cotejo__InsufficientDepth(att.depthUsd, floor);

        _consumed[digest] = true;
        _observation[att.asset] = Observation({
            price: att.price,
            observedAt: att.observedAt,
            depthUsd: att.depthUsd,
            reporter: reporter,
            decimals: att.decimals
        });

        emit AttestationAccepted(att.asset, reporter, att.price, att.decimals, att.observedAt, att.depthUsd);
    }

    /// @notice EIP-712 digest for an attestation, as reporters must sign it.
    /// @param att The attestation.
    /// @return digest The typed-data hash.
    function hashAttestation(PriceAttestation calldata att) public view returns (bytes32 digest) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    PRICE_ATTESTATION_TYPEHASH,
                    att.asset,
                    att.price,
                    att.decimals,
                    att.observedAt,
                    att.depthUsd,
                    att.sourceId
                )
            )
        );
    }

    // --------------------------------------------------------------------------------
    // Read path (IPriceSource) — all `view`, per D3
    // --------------------------------------------------------------------------------

    /// @inheritdoc IPriceSource
    function latestPrice(bytes32 asset)
        external
        view
        override
        returns (uint256 price, uint8 decimals, uint256 observedAt, bytes32 group)
    {
        if (!_assetEnabled[asset]) revert CotejoErrors.Cotejo__AssetNotSupported(asset);

        Observation memory obs = _observation[asset];
        if (obs.observedAt == 0) revert CotejoErrors.Cotejo__NoPrice(asset);

        return (obs.price, obs.decimals, obs.observedAt, _operatorGroup);
    }

    /// @inheritdoc IPriceSource
    function operatorGroupOf(bytes32 asset) external view override returns (bytes32 group) {
        return _assetEnabled[asset] ? _operatorGroup : bytes32(0);
    }

    /// @inheritdoc IPriceSource
    function supportsAsset(bytes32 asset) external view override returns (bool supported) {
        return _assetEnabled[asset];
    }

    /// @inheritdoc IPriceSource
    /// @dev Reverts on exactly the conditions `latestPrice` does, so the router can aggregate
    ///      depth over the same fresh set it prices from rather than a set assembled by
    ///      different rules.
    function latestDepthUsd(bytes32 asset) external view override returns (uint256 depthUsd) {
        if (!_assetEnabled[asset]) revert CotejoErrors.Cotejo__AssetNotSupported(asset);

        Observation memory obs = _observation[asset];
        if (obs.observedAt == 0) revert CotejoErrors.Cotejo__NoPrice(asset);

        return obs.depthUsd;
    }

    /// @notice The full stored observation for `asset`, including the depth behind it.
    /// @dev `IPriceSource.latestPrice` returns only what the router needs to aggregate. This
    ///      returns everything a third party needs to audit the reading without trusting
    ///      anyone: the depth the reporter claimed, and which key signed for it.
    ///      Reverts on the same conditions as `latestPrice`, so an unusable asset cannot be
    ///      inspected into looking usable.
    /// @param asset Identifier of the asset.
    /// @return price Price expressed in `decimals`.
    /// @return decimals Decimals `price` is scaled by.
    /// @return observedAt Unix timestamp of observation at the origin venue.
    /// @return depthUsd Market depth behind the observation, in whole USD.
    /// @return reporter Key that signed the attestation.
    /// @return group Operator group this source currently belongs to.
    function latestObservation(bytes32 asset)
        external
        view
        returns (
            uint256 price,
            uint8 decimals,
            uint256 observedAt,
            uint256 depthUsd,
            address reporter,
            bytes32 group
        )
    {
        if (!_assetEnabled[asset]) revert CotejoErrors.Cotejo__AssetNotSupported(asset);

        Observation memory obs = _observation[asset];
        if (obs.observedAt == 0) revert CotejoErrors.Cotejo__NoPrice(asset);

        return (obs.price, obs.decimals, obs.observedAt, obs.depthUsd, obs.reporter, _operatorGroup);
    }

    /// @notice The source's current operator group, regardless of asset.
    function operatorGroup() external view returns (bytes32 group) {
        return _operatorGroup;
    }

    /// @notice Whether `reporter` is registered on this source.
    function isReporter(address reporter) external view returns (bool registered) {
        return _isReporter[reporter];
    }

    /// @notice Whether `reporter` may attest to `asset`.
    function isAuthorised(address reporter, bytes32 asset) external view returns (bool allowed) {
        return _isReporter[reporter] && _authorised[reporter][asset];
    }

    /// @notice Minimum market depth, in whole USD, an attestation for `asset` must carry.
    function minDepthUsd(bytes32 asset) external view returns (uint256 floorUsd) {
        return _minDepthUsd[asset];
    }

    /// @notice Whether an attestation digest has already been consumed.
    function isConsumed(bytes32 digest) external view returns (bool used) {
        return _consumed[digest];
    }

    // --------------------------------------------------------------------------------
    // Administration
    // --------------------------------------------------------------------------------

    /// @notice Enables or disables an asset and sets its minimum depth.
    /// @dev Disabling makes `latestPrice` revert immediately, which drops this source out
    ///      of any route's fresh set. That is a fail-closed action, not a price write.
    function setAsset(bytes32 asset, bool enabled, uint256 minDepthUsd_) external onlyOwner {
        _assetEnabled[asset] = enabled;
        _minDepthUsd[asset] = minDepthUsd_;
        emit AssetEnabled(asset, enabled, minDepthUsd_);
    }

    /// @notice Registers or removes a reporter key.
    function setReporter(address reporter, bool registered) external onlyOwner {
        if (reporter == address(0)) revert CotejoErrors.Cotejo__UnknownReporter(reporter);
        _isReporter[reporter] = registered;
        emit ReporterSet(reporter, registered);
    }

    /// @notice Grants or revokes a reporter's authorisation for one asset.
    function setReporterAuthorisation(address reporter, bytes32 asset, bool allowed) external onlyOwner {
        _authorised[reporter][asset] = allowed;
        emit ReporterAuthorisationSet(reporter, asset, allowed);
    }

    /// @notice Changes the source's operator group.
    /// @dev This is the move INV-5 is built to survive. A route committed while this source
    ///      sat in group A stays committed when the owner moves it to group B, so the router
    ///      re-reads the group on every price read and reverts if concentration now exceeds
    ///      the route's limit.
    function setOperatorGroup(bytes32 newGroup) external onlyOwner {
        if (newGroup == bytes32(0)) revert CotejoErrors.Cotejo__InvalidRouteParameter();
        bytes32 previous = _operatorGroup;
        _operatorGroup = newGroup;
        emit OperatorGroupUpdated(previous, newGroup);
    }
}
