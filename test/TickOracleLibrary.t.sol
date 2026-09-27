// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ITickOracleHook} from "../src/interfaces/ITickOracleHook.sol";
import {TickOracleLibrary} from "../src/libraries/TickOracleLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {TickOracleHookFixture} from "./utils/TickOracleHookFixture.sol";

contract TickOracleLibraryTest is TickOracleHookFixture {
    function testConsultAcrossUnevenBlocksAndRingWrap() public {
        openPool(keyAB);
        ITickOracleHook reader = ITickOracleHook(address(hook));
        hook.increaseObservationCardinalityNext(keyAB, 5);
        assertEq(TickOracleLibrary.getOldestObservationSecondsAgo(reader, keyAB), 0);

        uint256[9] memory times;
        int24[9] memory ticks;
        times[0] = block.timestamp;
        ticks[0] = currentTick(keyAB);
        uint32[8] memory gaps = [uint32(2), 7, 1, 9, 3, 5, 2, 11];

        for (uint256 i = 1; i <= gaps.length; i++) {
            vm.warp(block.timestamp + gaps[i - 1]);
            vm.roll(block.number + 1);
            times[i] = block.timestamp;
            ticks[i] = swap(keyAB, i % 2 == 1);

            uint256 oldestIndex = i > 4 ? i - 4 : 0;
            assertEq(
                TickOracleLibrary.getOldestObservationSecondsAgo(reader, keyAB),
                times[i] - times[oldestIndex],
                "oldest age"
            );
            _assertAllWindows(reader, times, ticks, i, oldestIndex);
        }
    }

    function testBlockStartingTickAndSameBlockSwaps() public {
        openPool(keyAB);
        ITickOracleHook reader = ITickOracleHook(address(hook));
        vm.expectRevert(bytes("NEO"));
        this.blockStartingTick(keyAB);

        hook.increaseObservationCardinalityNext(keyAB, 4);
        vm.warp(block.timestamp + 3);
        vm.roll(block.number + 1);
        int24 firstTick = swap(keyAB, true);
        assertEq(TickOracleLibrary.getBlockStartingTick(reader, keyAB), 0);
        swap(keyAB, true);
        swap(keyAB, false);
        assertEq(TickOracleLibrary.getBlockStartingTick(reader, keyAB), 0, "same-block swaps changed start");

        vm.warp(block.timestamp + 7);
        vm.roll(block.number + 1);
        int24 previousTick = currentTick(keyAB);
        assertEq(TickOracleLibrary.getBlockStartingTick(reader, keyAB), previousTick);
        swap(keyAB, false);
        assertEq(TickOracleLibrary.getBlockStartingTick(reader, keyAB), previousTick);
        assertTrue(firstTick != 0, "first swap did not move the tick");
    }

    function testTimestampWrap() public {
        vm.warp(uint256(type(uint32).max) - 3);
        openPool(keyAB);
        ITickOracleHook reader = ITickOracleHook(address(hook));
        hook.increaseObservationCardinalityNext(keyAB, 4);

        uint256[9] memory times;
        int24[9] memory ticks;
        times[0] = block.timestamp;
        ticks[0] = currentTick(keyAB);

        vm.warp(uint256(type(uint32).max) - 1);
        vm.roll(block.number + 1);
        times[1] = block.timestamp;
        ticks[1] = swap(keyAB, true);

        vm.warp(uint256(type(uint32).max) + 3);
        vm.roll(block.number + 1);
        times[2] = block.timestamp;
        ticks[2] = swap(keyAB, false);

        assertEq(TickOracleLibrary.getOldestObservationSecondsAgo(reader, keyAB), 6);
        assertEq(TickOracleLibrary.getBlockStartingTick(reader, keyAB), ticks[1]);
        _assertAllWindows(reader, times, ticks, 2, 0);

        vm.warp(block.timestamp + 2);
        vm.roll(block.number + 1);
        assertEq(TickOracleLibrary.getBlockStartingTick(reader, keyAB), ticks[2]);
        assertEq(TickOracleLibrary.getOldestObservationSecondsAgo(reader, keyAB), 8);
        _assertAllWindows(reader, times, ticks, 2, 0);
    }

    function testUninitializedAndZeroWindowReverts() public {
        vm.expectRevert(bytes("NI"));
        this.oldestObservationSecondsAgo(keyAB);
        vm.expectRevert(bytes("NEO"));
        this.blockStartingTick(keyAB);
        vm.expectRevert(bytes("BP"));
        this.consultZero(keyAB);
    }

    function testQuoteAtTicksAndSqrtRatioBoundary() public pure {
        int24[7] memory ticks = [int24(-887272), -1, 0, 1, 887272, 443636, 443637];
        uint256[7] memory forward = [
            uint256(0),
            999900009999000099,
            1000000000000000000,
            1000100000000000000,
            340256786836388094070642339899681172762184831912720469415,
            18446050711097703529776342895654370894,
            18447895316168813300129320530133980662
        ];
        uint256[7] memory reverse = [
            uint256(340256786698763678858396856460488307819979090561464864775),
            1000099999999999999,
            1000000000000000000,
            999900009999000099,
            0,
            0,
            0
        ];
        for (uint256 i; i < ticks.length; i++) {
            assertEq(TickOracleLibrary.getQuoteAtTick(ticks[i], 1 ether, address(1), address(2)), forward[i]);
            assertEq(TickOracleLibrary.getQuoteAtTick(ticks[i], 1 ether, address(2), address(1)), reverse[i]);
        }

        assertLe(TickMath.getSqrtPriceAtTick(443636), type(uint128).max);
        assertGt(TickMath.getSqrtPriceAtTick(443637), type(uint128).max);
        assertEq(
            TickOracleLibrary.getQuoteAtTick(443636, type(uint128).max, address(2), address(1)), 18447437462383981825
        );
        assertEq(
            TickOracleLibrary.getQuoteAtTick(443637, type(uint128).max, address(2), address(1)), 18445592903093672458
        );
    }

    function testWeightedArithmeticMeanTickRoundsDown() public pure {
        TickOracleLibrary.WeightedTickData[] memory data = new TickOracleLibrary.WeightedTickData[](3);
        data[0] = TickOracleLibrary.WeightedTickData({tick: -5, weight: 1});
        data[1] = TickOracleLibrary.WeightedTickData({tick: 2, weight: 2});
        data[2] = TickOracleLibrary.WeightedTickData({tick: 1, weight: 1});
        assertEq(TickOracleLibrary.getWeightedArithmeticMeanTick(data), 0);
        data[2].tick = 0;
        assertEq(TickOracleLibrary.getWeightedArithmeticMeanTick(data), -1);
    }

    function blockStartingTick(PoolKey memory key) external view returns (int24) {
        return TickOracleLibrary.getBlockStartingTick(ITickOracleHook(address(hook)), key);
    }

    function oldestObservationSecondsAgo(PoolKey memory key) external view returns (uint32) {
        return TickOracleLibrary.getOldestObservationSecondsAgo(ITickOracleHook(address(hook)), key);
    }

    function consultZero(PoolKey memory key) external view returns (int24) {
        return TickOracleLibrary.consult(ITickOracleHook(address(hook)), key, 0);
    }

    /// @dev Integrates the recorded post-swap tick over each interval, independent of observe's interpolation.
    function _assertAllWindows(
        ITickOracleHook reader,
        uint256[9] memory times,
        int24[9] memory ticks,
        uint256 latest,
        uint256 oldest
    ) internal view {
        uint256 nowTime = block.timestamp;
        for (uint256 window = 1; window <= nowTime - times[oldest]; window++) {
            uint256 target = nowTime - window;
            int256 weighted;
            for (uint256 j = oldest; j <= latest; j++) {
                uint256 left = times[j];
                uint256 right = j == latest ? nowTime : times[j + 1];
                if (right > target) {
                    weighted += int256(ticks[j]) * int256(right - (left > target ? left : target));
                }
            }
            int24 expected = int24(floorDiv(weighted, int256(window)));
            assertEq(TickOracleLibrary.consult(reader, keyAB, uint32(window)), expected, "library mean");
            assertEq(hook.consult(keyAB, uint32(window)), expected, "hook mean");
        }
    }
}
