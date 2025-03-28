/**
 * Created by Pragma Labs
 * SPDX-License-Identifier: MIT
 */
pragma solidity 0.8.22;

import { AlienBaseLogic } from "../../../../alien-base/libraries/AlienBaseLogic.sol";
import { CompounderHelper } from "../../../CompounderHelper.sol";
import { Fees, PositionState } from "../../../../uniswap-v3/interfaces/IUniswapV3Compounder.sol";
import { FixedPoint128 } from
    "../../../../../../lib/accounts-v2/src/asset-modules/UniswapV3/libraries/FixedPoint128.sol";
import { FixedPointMathLib } from "../../../../../../lib/accounts-v2/lib/solmate/src/utils/FixedPointMathLib.sol";
import { FullMath } from "../../../../../../lib/accounts-v2/src/asset-modules/UniswapV3/libraries/FullMath.sol";
import { INonfungiblePositionManager } from "../../../../uniswap-v3/interfaces/INonfungiblePositionManager.sol";
import { IQuoter, QuoteExactOutputSingleParams } from "../../../../uniswap-v3/interfaces/IQuoter.sol";
import { IUniswapV3Compounder } from "../../../../uniswap-v3/interfaces/IUniswapV3Compounder.sol";
import { IUniswapV3Pool } from "../../../../uniswap-v3/interfaces/IUniswapV3Pool.sol";
import { LiquidityAmounts } from "../../../../libraries/LiquidityAmounts.sol";
import { UniswapV3Logic } from "../../../../uniswap-v3/libraries/UniswapV3Logic.sol";

library UniswapV3SpotHelperLogic {
    using FixedPointMathLib for uint256;

    // The UniswapV3 Quoter contract.
    IQuoter internal constant QUOTER_UNISWAPV3 = IQuoter(0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a);
    // The AlienBase Quoter contract.
    IQuoter internal constant QUOTER_ALIENBASE = IQuoter(0x2ba1d35920DB74a1dB97679BC27d2cBa81bB96ea);

    // The contract address of the Compounder for Spot Accounts.
    // TODO : Replace with deployed contracts.
    IUniswapV3Compounder public constant COMPOUNDER_SPOT_UNISWAPV3 = IUniswapV3Compounder(address(0x00));
    IUniswapV3Compounder public constant COMPOUNDER_SPOT_ALIENBASE = IUniswapV3Compounder(address(0x00));

    /**
     * @notice Off-chain view function to check if the fees of a certain Liquidity Position can be compounded for Spot Accounts.
     * @param tokenId The id of the Liquidity Position.
     * @param positionManager The address of the position manager.
     * @return isCompoundable_ Bool indicating if the fees can be compounded.
     * @return info A struct containing the info to value the fees.
     * @return compounder_ The address of the Compounder.
     * @dev While this function does not persist state changes, it cannot be declared as view function.
     * Since quoteExactOutputSingle() of Uniswap's Quoter02.sol uses a try - except pattern where it first
     * does the swap (with state changes), next it reverts (state changes are not persisted) and information about
     * the final state is passed via the error message in the expect.
     */
    function isCompoundable(uint256 tokenId, address positionManager)
        public
        returns (bool isCompoundable_, CompounderHelper.SpotAccountInfo memory info, address compounder_)
    {
        IUniswapV3Compounder compounder = positionManager == address(UniswapV3Logic.POSITION_MANAGER)
            ? COMPOUNDER_SPOT_UNISWAPV3
            : COMPOUNDER_SPOT_ALIENBASE;

        // Fetch and cache all position related data.
        PositionState memory position = compounder.getPositionState(tokenId);

        // Check that pool is initially balanced.
        // Prevents sandwiching attacks when swapping and/or adding liquidity.
        if (compounder.isPoolUnbalanced(position)) return (false, info, address(0));

        // Get fee amounts
        Fees memory balances;
        (balances.amount0, balances.amount1) = _getFeeAmounts(tokenId, positionManager);

        // Remove initiator reward from fees, these will be send to the initiator.
        Fees memory desiredAmounts;
        uint256 initiatorShare = compounder.INITIATOR_SHARE();
        desiredAmounts.amount0 = balances.amount0 - balances.amount0.mulDivDown(initiatorShare, 1e18);
        desiredAmounts.amount1 = balances.amount1 - balances.amount1.mulDivDown(initiatorShare, 1e18);

        // Calculate fee amounts to match ratios of current pool tick relative to ticks of the position.
        (bool zeroToOne, uint256 amountOut) = compounder.getSwapParameters(position, desiredAmounts);
        (bool isPoolUnbalanced, uint256 amountIn) = _quote(positionManager, position, zeroToOne, amountOut);

        // Pool should still be balanced after the swap.
        if (isPoolUnbalanced) return (false, info, address(0));

        // Get values to return for Spot Accounts.
        info.token0 = position.token0;
        info.token1 = position.token1;
        info.feeAmount0 = balances.amount0;
        info.feeAmount1 = balances.amount1;

        // Calculate balances after swap.
        // Note that for the desiredAmounts only tokenOut is updated in UniswapV3Compounder,
        // but not tokenIn.
        if (zeroToOne) {
            desiredAmounts.amount1 += amountOut;
            balances.amount0 -= amountIn;
            balances.amount1 += amountOut;
        } else {
            desiredAmounts.amount0 += amountOut;
            balances.amount0 += amountOut;
            balances.amount1 -= amountIn;
        }

        // The balances of the fees after swapping must be bigger than the actual input amount when increasing liquidity.
        // Due to slippage, or for pools with high swapping fees this might not always hold.
        (uint256 amount0, uint256 amount1) = _getLiquidityAmounts(position, desiredAmounts);
        return (balances.amount0 > amount0 && balances.amount1 > amount1, info, address(compounder));
    }

    /**
     * @notice Off-chain view function to get the quote of a swap.
     * @param positionManager The address of the position manager.
     * @param position Struct with the position data.
     * @param zeroToOne Bool indicating if token0 has to be swapped to token1 or opposite.
     * @param amountOut The amount of tokenOut that must be swapped to.
     * @return isPoolUnbalanced Bool indicating if the pool is unbalanced due to slippage after the swap.
     * @return amountIn The amount of tokenIn that is swapped to tokenOut.
     * @dev While this function does not persist state changes, it cannot be declared as view function,
     * since quoteExactOutputSingle() of Slipstream's Quoter02.sol uses a try - except pattern where it first
     * does the swap (with state changes), next it reverts (state changes are not persisted) and information about
     * the final state is passed via the error message in the expect.
     */
    function _quote(address positionManager, PositionState memory position, bool zeroToOne, uint256 amountOut)
        internal
        returns (bool isPoolUnbalanced, uint256 amountIn)
    {
        IQuoter quoter =
            positionManager == address(UniswapV3Logic.POSITION_MANAGER) ? QUOTER_UNISWAPV3 : QUOTER_ALIENBASE;

        // Don't get quote for swaps with zero amount.
        if (amountOut == 0) return (false, 0);

        // Max slippage: Pool should still be balanced after the swap.
        uint256 sqrtPriceLimitX96 = zeroToOne ? position.lowerBoundSqrtPriceX96 : position.upperBoundSqrtPriceX96;

        // Quote the swap.
        uint160 sqrtPriceX96After;
        (amountIn, sqrtPriceX96After,,) = quoter.quoteExactOutputSingle(
            QuoteExactOutputSingleParams({
                tokenIn: zeroToOne ? position.token0 : position.token1,
                tokenOut: zeroToOne ? position.token1 : position.token0,
                amountOut: amountOut,
                fee: position.fee,
                sqrtPriceLimitX96: uint160(sqrtPriceLimitX96)
            })
        );

        // Check if max slippage was exceeded (sqrtPriceLimitX96 is reached).
        isPoolUnbalanced = sqrtPriceX96After == sqrtPriceLimitX96 ? true : false;

        // Update the sqrtPriceX96 of the pool.
        position.sqrtPriceX96 = sqrtPriceX96After;
    }

    /**
     * @notice Calculates the underlying token amounts of accrued fees, both collected and uncollected.
     * @param tokenId The id of the Liquidity Position.
     * @param positionManager The address of the position manager.
     * @return amount0 The amount of fees in underlying token0 tokens.
     * @return amount1 The amount of fees in underlying token1 tokens.
     */
    function _getFeeAmounts(uint256 tokenId, address positionManager)
        internal
        view
        returns (uint256 amount0, uint256 amount1)
    {
        (
            ,
            ,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint256 liquidity, // gas: cheaper to use uint256 instead of uint128.
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint256 tokensOwed0, // gas: cheaper to use uint256 instead of uint128.
            uint256 tokensOwed1 // gas: cheaper to use uint256 instead of uint128.
        ) = positionManager == address(UniswapV3Logic.POSITION_MANAGER)
            ? UniswapV3Logic.POSITION_MANAGER.positions(tokenId)
            : AlienBaseLogic.POSITION_MANAGER.positions(tokenId);

        (uint256 feeGrowthInside0CurrentX128, uint256 feeGrowthInside1CurrentX128) =
            _getFeeGrowthInside(positionManager, token0, token1, fee, tickLower, tickUpper);

        // Calculate the total amount of fees by adding the already realized fees (tokensOwed),
        // to the accumulated fees since the last time the position was updated:
        // (feeGrowthInsideCurrentX128 - feeGrowthInsideLastX128) * liquidity.
        // Fee calculations in NonfungiblePositionManager.sol overflow (without reverting) when
        // one or both terms, or their sum, is bigger than a uint128.
        // This is however much bigger than any realistic situation.
        unchecked {
            amount0 = FullMath.mulDiv(
                feeGrowthInside0CurrentX128 - feeGrowthInside0LastX128, liquidity, FixedPoint128.Q128
            ) + tokensOwed0;
            amount1 = FullMath.mulDiv(
                feeGrowthInside1CurrentX128 - feeGrowthInside1LastX128, liquidity, FixedPoint128.Q128
            ) + tokensOwed1;
        }
    }

    /**
     * @notice Calculates the current fee growth inside the Liquidity Range.
     * @param positionManager The address of the position manager.
     * @param token0 Token0 of the Liquidity Pool.
     * @param token1 Token1 of the Liquidity Pool.
     * @param fee The fee of the Liquidity Pool.
     * @param tickLower The lower tick of the liquidity position.
     * @param tickUpper The upper tick of the liquidity position.
     * @return feeGrowthInside0X128 The amount of fees in underlying token0 tokens.
     * @return feeGrowthInside1X128 The amount of fees in underlying token1 tokens.
     */
    function _getFeeGrowthInside(
        address positionManager,
        address token0,
        address token1,
        uint24 fee,
        int24 tickLower,
        int24 tickUpper
    ) internal view returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) {
        IUniswapV3Pool pool = positionManager == address(UniswapV3Logic.POSITION_MANAGER)
            ? IUniswapV3Pool(UniswapV3Logic._computePoolAddress(token0, token1, fee))
            : IUniswapV3Pool(AlienBaseLogic._computePoolAddress(token0, token1, fee));

        // To calculate the pending fees, the current tick has to be used, even if the pool would be unbalanced.
        (, int24 tickCurrent,,,,,) = pool.slot0();
        (,, uint256 lowerFeeGrowthOutside0X128, uint256 lowerFeeGrowthOutside1X128,,,,) = pool.ticks(tickLower);
        (,, uint256 upperFeeGrowthOutside0X128, uint256 upperFeeGrowthOutside1X128,,,,) = pool.ticks(tickUpper);

        // Calculate the fee growth inside of the Liquidity Range since the last time the position was updated.
        // feeGrowthInside can overflow (without reverting), as is the case in the Uniswap fee calculations.
        unchecked {
            if (tickCurrent < tickLower) {
                feeGrowthInside0X128 = lowerFeeGrowthOutside0X128 - upperFeeGrowthOutside0X128;
                feeGrowthInside1X128 = lowerFeeGrowthOutside1X128 - upperFeeGrowthOutside1X128;
            } else if (tickCurrent < tickUpper) {
                feeGrowthInside0X128 =
                    pool.feeGrowthGlobal0X128() - lowerFeeGrowthOutside0X128 - upperFeeGrowthOutside0X128;
                feeGrowthInside1X128 =
                    pool.feeGrowthGlobal1X128() - lowerFeeGrowthOutside1X128 - upperFeeGrowthOutside1X128;
            } else {
                feeGrowthInside0X128 = upperFeeGrowthOutside0X128 - lowerFeeGrowthOutside0X128;
                feeGrowthInside1X128 = upperFeeGrowthOutside1X128 - lowerFeeGrowthOutside1X128;
            }
        }
    }

    /**
     * @notice returns the actual amounts of token0 and token1 when increasing liquidity,
     * for a given position and desired amount of tokens.
     * @param position Struct with the position data.
     * @param amountsDesired Struct with the desired amounts of tokens supplied.
     * @return amount0 The actual amount of token0 supplied.
     * @return amount1 The actual amount of token1 supplied.
     */
    function _getLiquidityAmounts(PositionState memory position, Fees memory amountsDesired)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            uint160(position.sqrtPriceX96),
            uint160(position.sqrtRatioLower),
            uint160(position.sqrtRatioUpper),
            amountsDesired.amount0,
            amountsDesired.amount1
        );
        (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
            uint160(position.sqrtPriceX96),
            uint160(position.sqrtRatioLower),
            uint160(position.sqrtRatioUpper),
            liquidity
        );
    }
}
