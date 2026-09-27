// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

// Ported from Uniswap v3-periphery's OracleLibrary (GPL-2.0-or-later).
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {ITickOracleHook} from "../interfaces/ITickOracleHook.sol";

/// @title TickOracleLibrary
/// @notice Read helpers for the tick oracle in TickOracleHook.
/// @dev The hook has no seconds-per-liquidity observations, so these helpers return ticks only.
library TickOracleLibrary {
    /// @notice Returns the arithmetic mean tick over the last `secondsAgo` seconds.
    /// @dev Rounds toward negative infinity, as v3-periphery's OracleLibrary does.
    function consult(ITickOracleHook hook, PoolKey memory key, uint32 secondsAgo)
        internal
        view
        returns (int24 arithmeticMeanTick)
    {
        require(secondsAgo != 0, "BP");
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = secondsAgo;
        secondsAgos[1] = 0;
        int56[] memory tickCumulatives = hook.observe(key, secondsAgos);

        unchecked {
            int56 delta = tickCumulatives[1] - tickCumulatives[0];
            int56 secondsAgoSigned = int56(uint56(secondsAgo));
            arithmeticMeanTick = int24(delta / secondsAgoSigned);
            if (delta < 0 && delta % secondsAgoSigned != 0) arithmeticMeanTick--;
        }
    }

    /// @notice Quotes `baseAmount` at `tick`, with token order determining the price direction.
    function getQuoteAtTick(int24 tick, uint128 baseAmount, address baseToken, address quoteToken)
        internal
        pure
        returns (uint256 quoteAmount)
    {
        uint160 sqrtRatioX96 = TickMath.getSqrtPriceAtTick(tick);
        if (sqrtRatioX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
            quoteAmount = baseToken < quoteToken
                ? FullMath.mulDiv(ratioX192, baseAmount, 1 << 192)
                : FullMath.mulDiv(1 << 192, baseAmount, ratioX192);
        } else {
            uint256 ratioX128 = FullMath.mulDiv(sqrtRatioX96, sqrtRatioX96, 1 << 64);
            quoteAmount = baseToken < quoteToken
                ? FullMath.mulDiv(ratioX128, baseAmount, 1 << 128)
                : FullMath.mulDiv(1 << 128, baseAmount, ratioX128);
        }
    }

    /// @notice Returns the age of the oldest observation still in the pool's buffer.
    function getOldestObservationSecondsAgo(ITickOracleHook hook, PoolKey memory key)
        internal
        view
        returns (uint32 secondsAgo)
    {
        PoolId id = key.toId();
        (uint16 index, uint16 cardinality,,) = hook.states(id);
        require(cardinality > 0, "NI");
        (uint32 timestamp,, bool initialized) = hook.observations(id, (uint256(index) + 1) % cardinality);
        if (!initialized) (timestamp,,) = hook.observations(id, 0);
        unchecked {
            secondsAgo = uint32(block.timestamp) - timestamp;
        }
    }

    /// @notice Returns the tick that stood at the start of the current block.
    function getBlockStartingTick(ITickOracleHook hook, PoolKey memory key) internal view returns (int24 tick) {
        PoolId id = key.toId();
        (uint16 index, uint16 cardinality,, int24 lastTick) = hook.states(id);
        require(cardinality > 1, "NEO");
        (uint32 timestamp, int56 cumulative,) = hook.observations(id, index);
        if (timestamp != uint32(block.timestamp)) return lastTick;

        uint256 previousIndex = (uint256(index) + cardinality - 1) % cardinality;
        (uint32 previousTimestamp, int56 previousCumulative, bool initialized) = hook.observations(id, previousIndex);
        require(initialized, "ONI");
        unchecked {
            uint32 elapsed = timestamp - previousTimestamp;
            tick = int24((cumulative - previousCumulative) / int56(uint56(elapsed)));
        }
    }

    struct WeightedTickData {
        int24 tick;
        uint128 weight;
    }

    /// @notice Returns the weighted mean tick, rounded toward negative infinity.
    /// @dev Ticks should describe pools with the same underlying tokens and comparable decimals.
    function getWeightedArithmeticMeanTick(WeightedTickData[] memory weightedTickData)
        internal
        pure
        returns (int24 weightedArithmeticMeanTick)
    {
        int256 numerator;
        uint256 denominator;
        for (uint256 i; i < weightedTickData.length; i++) {
            numerator += int256(weightedTickData[i].tick) * int256(uint256(weightedTickData[i].weight));
            denominator += weightedTickData[i].weight;
        }
        int256 denominatorSigned = int256(denominator);
        weightedArithmeticMeanTick = int24(numerator / denominatorSigned);
        if (numerator < 0 && numerator % denominatorSigned != 0) weightedArithmeticMeanTick--;
    }
}
