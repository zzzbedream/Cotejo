// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {ChainlinkCompatSource} from "../../src/sources/ChainlinkCompatSource.sol";
import {CotejoErrors} from "../../src/libraries/CotejoErrors.sol";
import {MockAggregatorV3} from "../helpers/MockAggregatorV3.sol";

/// @notice Unit tests for the external-aggregator wrapper.
/// @dev No Chainlink feed exists on Whitechain today, so every case here runs against a
///      stand-in. The tests are about the wrapper's own safety checks, which are exactly what
///      would matter on the day a real feed appears.
contract ChainlinkCompatSourceTest is Test {
    bytes32 private constant WBT_USD = keccak256("WBT/USD");
    bytes32 private constant OTHER_ASSET = keccak256("ETH/USD");
    bytes32 private constant GROUP_A = keccak256("operator.a");
    bytes32 private constant GROUP_B = keccak256("operator.b");

    address private owner = makeAddr("owner");
    address private outsider = makeAddr("outsider");

    MockAggregatorV3 private feed;
    ChainlinkCompatSource private source;

    function setUp() public {
        vm.warp(1_750_000_000);
        feed = new MockAggregatorV3();
        source = new ChainlinkCompatSource(address(feed), WBT_USD, GROUP_A, owner);
    }

    function test_servesAPositiveAnswer() public {
        feed.setAnswer(100e8, block.timestamp);

        (uint256 price, uint8 decimals, uint256 observedAt, bytes32 group) = source.latestPrice(WBT_USD);

        assertEq(price, 100e8);
        assertEq(decimals, 8);
        assertEq(observedAt, block.timestamp);
        assertEq(group, GROUP_A);
    }

    function test_revertsForAnotherAsset() public {
        feed.setAnswer(100e8, block.timestamp);

        vm.expectRevert(abi.encodeWithSelector(CotejoErrors.Cotejo__AssetNotSupported.selector, OTHER_ASSET));
        source.latestPrice(OTHER_ASSET);
    }

    function test_revertsWhenFeedHasNeverUpdated() public {
        // updatedAt == 0 is Chainlink's "no data" signal.
        vm.expectRevert(abi.encodeWithSelector(CotejoErrors.Cotejo__NoPrice.selector, WBT_USD));
        source.latestPrice(WBT_USD);
    }

    function test_revertsWhenRoundWasCarriedOver() public {
        feed.setAnswer(100e8, block.timestamp);
        feed.setRound(10, 9); // answeredInRound < roundId

        vm.expectRevert(abi.encodeWithSelector(CotejoErrors.Cotejo__NoPrice.selector, WBT_USD));
        source.latestPrice(WBT_USD);
    }

    function test_revertsOnNonPositiveAnswer() public {
        feed.setAnswer(0, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(CotejoErrors.Cotejo__ZeroPrice.selector, WBT_USD));
        source.latestPrice(WBT_USD);

        feed.setAnswer(-1, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(CotejoErrors.Cotejo__ZeroPrice.selector, WBT_USD));
        source.latestPrice(WBT_USD);
    }

    function test_reportsAssetSupportAndOperatorGroup() public view {
        assertTrue(source.supportsAsset(WBT_USD));
        assertFalse(source.supportsAsset(OTHER_ASSET));
        assertEq(source.operatorGroupOf(WBT_USD), GROUP_A);
        assertEq(source.operatorGroupOf(OTHER_ASSET), bytes32(0));
        assertEq(source.operatorGroup(), GROUP_A);
    }

    function test_ownerCanMoveOperatorGroup() public {
        vm.prank(owner);
        source.setOperatorGroup(GROUP_B);
        assertEq(source.operatorGroupOf(WBT_USD), GROUP_B);
    }

    function test_onlyOwnerCanMoveOperatorGroup() public {
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider));
        source.setOperatorGroup(GROUP_B);
    }

    function test_rejectsZeroOperatorGroup() public {
        vm.prank(owner);
        vm.expectRevert(CotejoErrors.Cotejo__InvalidRouteParameter.selector);
        source.setOperatorGroup(bytes32(0));
    }

    function test_constructorRejectsZeroArguments() public {
        vm.expectRevert(CotejoErrors.Cotejo__InvalidRouteParameter.selector);
        new ChainlinkCompatSource(address(0), WBT_USD, GROUP_A, owner);

        vm.expectRevert(CotejoErrors.Cotejo__InvalidRouteParameter.selector);
        new ChainlinkCompatSource(address(feed), bytes32(0), GROUP_A, owner);

        vm.expectRevert(CotejoErrors.Cotejo__InvalidRouteParameter.selector);
        new ChainlinkCompatSource(address(feed), WBT_USD, bytes32(0), owner);
    }

    function test_exposesImmutableBindings() public view {
        assertEq(address(source.AGGREGATOR()), address(feed));
        assertEq(source.ASSET(), WBT_USD);
    }
}
