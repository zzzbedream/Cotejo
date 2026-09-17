// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {CotejoTestBase} from "../helpers/CotejoTestBase.sol";
import {CotejoAggregatorAdapter} from "../../src/adapters/CotejoAggregatorAdapter.sol";
import {CotejoErrors} from "../../src/libraries/CotejoErrors.sol";

/// @notice Unit tests for the AggregatorV3-compatible façade.
contract CotejoAggregatorAdapterTest is CotejoTestBase {
    CotejoAggregatorAdapter private adapter;

    function setUp() public override {
        super.setUp();
        _commitRoute(WBT_USD, _defaultRoute());
        adapter = new CotejoAggregatorAdapter(address(router), WBT_USD, 8, "WBT / USD");
    }

    function test_reportsStaticMetadata() public view {
        assertEq(adapter.decimals(), 8);
        assertEq(adapter.description(), "WBT / USD");
        assertEq(adapter.version(), 1);
        assertEq(address(adapter.ROUTER()), address(router));
        assertEq(adapter.ASSET(), WBT_USD);
    }

    function test_latestRoundDataRescalesToAdapterDecimals() public {
        _setAllPrices(100e18);

        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            adapter.latestRoundData();

        assertEq(answer, 100e8, "18-decimal router price must arrive as 8 decimals");
        assertEq(startedAt, block.timestamp);
        assertEq(updatedAt, block.timestamp);
        assertEq(roundId, uint80(block.timestamp), "roundId is derived from observedAt");
        assertEq(answeredInRound, roundId, "answeredInRound must satisfy the usual consumer check");
    }

    function test_latestRoundDataReportsOldestObservation() public {
        uint256 oldest = block.timestamp - 120;
        sourceA.set(100e18, 18, block.timestamp);
        sourceB.set(100e18, 18, oldest);
        sourceC.set(100e18, 18, block.timestamp);

        (,, uint256 startedAt, uint256 updatedAt,) = adapter.latestRoundData();
        assertEq(startedAt, oldest);
        assertEq(updatedAt, oldest);
    }

    function test_getRoundDataAlwaysReverts() public {
        _setAllPrices(100e18);

        vm.expectRevert(
            abi.encodeWithSelector(CotejoErrors.Cotejo__HistoricalDataUnavailable.selector, uint80(1))
        );
        adapter.getRoundData(1);
    }

    function test_propagatesRouterRefusalUnchanged() public {
        // Only one fresh source; INV-1 refuses and the consumer sees the exact reason.
        sourceA.set(100e18, 18, block.timestamp);

        vm.expectRevert(
            abi.encodeWithSelector(CotejoErrors.Cotejo__InsufficientSources.selector, WBT_USD, 1, 2)
        );
        adapter.latestRoundData();
    }

    function test_propagatesPauseUnchanged() public {
        _setAllPrices(100e18);

        vm.prank(guardian);
        router.pause(WBT_USD);

        vm.expectRevert(abi.encodeWithSelector(CotejoErrors.Cotejo__Paused.selector, WBT_USD));
        adapter.latestRoundData();
    }

    function test_revertsRatherThanRoundingAPriceToZero() public {
        // A price so small that expressing it with 8 decimals would round it to nothing.
        _setAllPrices(1);

        vm.expectRevert(abi.encodeWithSelector(CotejoErrors.Cotejo__PrecisionLoss.selector, 1, 18, 8));
        adapter.latestRoundData();
    }

    function test_constructorRejectsInvalidArguments() public {
        vm.expectRevert(CotejoErrors.Cotejo__InvalidRouteParameter.selector);
        new CotejoAggregatorAdapter(address(0), WBT_USD, 8, "x");

        vm.expectRevert(CotejoErrors.Cotejo__InvalidRouteParameter.selector);
        new CotejoAggregatorAdapter(address(router), bytes32(0), 8, "x");

        vm.expectRevert(abi.encodeWithSelector(CotejoErrors.Cotejo__DecimalsOutOfRange.selector, 37));
        new CotejoAggregatorAdapter(address(router), WBT_USD, 37, "x");
    }

    function test_supportsHigherPrecisionThanTheRouter() public {
        CotejoAggregatorAdapter wide =
            new CotejoAggregatorAdapter(address(router), WBT_USD, 24, "WBT / USD wide");
        _setAllPrices(100e18);

        (, int256 answer,,,) = wide.latestRoundData();
        assertEq(answer, 100e24);
    }
}
