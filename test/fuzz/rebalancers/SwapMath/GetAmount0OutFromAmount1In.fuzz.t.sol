/**
 * Created by Pragma Labs
 * SPDX-License-Identifier: BUSL-1.1
 */
pragma solidity 0.8.22;

import { FullMath } from "../../../../lib/accounts-v2/src/asset-modules/UniswapV3/libraries/FullMath.sol";
import { FixedPoint96 } from "../../../../lib/accounts-v2/src/asset-modules/UniswapV3/libraries/FixedPoint96.sol";
import { SwapMath_Fuzz_Test } from "./_SwapMath.fuzz.t.sol";
import { TickMath } from "../../../../lib/accounts-v2/src/asset-modules/UniswapV3/libraries/TickMath.sol";

/**
 * @notice Fuzz tests for the function "_getAmount0OutFromAmount1In" of contract "SwapMath".
 */
contract GetAmount0OutFromAmount1In_SwapMath_Fuzz_Test is SwapMath_Fuzz_Test {
    /* ///////////////////////////////////////////////////////////////
                              SETUP
    /////////////////////////////////////////////////////////////// */

    function setUp() public override {
        SwapMath_Fuzz_Test.setUp();
    }

    /*//////////////////////////////////////////////////////////////
                              TESTS
    //////////////////////////////////////////////////////////////*/
    function testFuzz_Success_getAmount0OutFromAmount1In(
        uint256 fee,
        uint128 usableLiquidity,
        uint160 sqrtPriceOld,
        uint128 amount1
    ) public {
        // Given: fee is smaller than 1e6 (invariant).
        fee = bound(fee, 0, 1e6);

        // And: usableLiquidity is not near zero.
        usableLiquidity = uint128(bound(usableLiquidity, 1e18, type(uint128).max));

        // And: sqrtPriceOld is within boundaries and smaller than type(uint128).max.
        sqrtPriceOld = uint160(bound(sqrtPriceOld, TickMath.MIN_SQRT_RATIO, TickMath.MIN_SQRT_RATIO));

        // And: amountOut without slippage would not overflow.
        sqrtPriceOld = uint160(bound(sqrtPriceOld, TickMath.MIN_SQRT_RATIO, TickMath.MIN_SQRT_RATIO));
        if (sqrtPriceOld > FixedPoint96.Q96) {
            amount1 = uint128(
                bound(amount1, 0, type(uint256).max / sqrtPriceOld * FixedPoint96.Q96 / sqrtPriceOld * FixedPoint96.Q96)
            );
        }

        // When: calling _getAmount0OutFromAmount1In().
        // Then: it does not revert.
        uint256 amountOut = swapMath.getAmount0OutFromAmount1In(fee, usableLiquidity, sqrtPriceOld, amount1);

        // And: amountOut is always smaller or equal than result without slippage.
        uint256 amountOutWithoutSlippage = FullMath.mulDiv(amount1, FixedPoint96.Q96, sqrtPriceOld);
        amountOutWithoutSlippage = FullMath.mulDiv(amountOutWithoutSlippage, FixedPoint96.Q96, sqrtPriceOld);
        assertLe(amountOut, amountOutWithoutSlippage);
    }
}
