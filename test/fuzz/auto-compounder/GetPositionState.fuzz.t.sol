/**
 * Created by Pragma Labs
 * SPDX-License-Identifier: BUSL-1.1
 */
pragma solidity 0.8.22;

import { AutoCompounder_Fuzz_Test, AutoCompounder } from "./_AutoCompounder.fuzz.t.sol";
import { FixedPointMathLib } from "../../../lib/accounts-v2/lib/solmate/src/utils/FixedPointMathLib.sol";
import { UniswapV3Logic } from "../../../src/auto-compounder/libraries/UniswapV3Logic.sol";

/**
 * @notice Fuzz tests for the function "_getPositionState" of contract "AutoCompounder".
 */
contract GetPositionState_AutoCompounder_Fuzz_Test is AutoCompounder_Fuzz_Test {
    using FixedPointMathLib for uint256;
    /* ///////////////////////////////////////////////////////////////
                              SETUP
    /////////////////////////////////////////////////////////////// */

    function setUp() public override {
        AutoCompounder_Fuzz_Test.setUp();
    }

    /*//////////////////////////////////////////////////////////////
                              TESTS
    //////////////////////////////////////////////////////////////*/
    function testFuzz_success_getPositionState(TestVariables memory testVars) public {
        // Given : Valid State
        bool token0HasLowestDecimals;
        (testVars, token0HasLowestDecimals) = givenValidBalancedState(testVars);

        // And : State is persisted
        uint256 tokenId = setState(testVars, usdStablePool);

        // When : Calling getPositionState()
        AutoCompounder.PositionState memory position = autoCompounder.getPositionState(tokenId);

        // Then : It should return the correct values
        assertEq(position.token0, address(token0));
        assertEq(position.token1, address(token1));
        assertEq(position.fee, POOL_FEE);
        assertEq(position.tickLower, testVars.tickLower);
        assertEq(position.tickUpper, testVars.tickUpper);

        uint256 priceToken0 = token0HasLowestDecimals ? 1e30 : 1e18;
        uint256 priceToken1 = token0HasLowestDecimals ? 1e18 : 1e30;

        assertEq(position.usdPriceToken0, priceToken0);
        assertEq(position.usdPriceToken1, priceToken1);

        assertEq(position.pool, address(usdStablePool));

        (uint160 sqrtPriceX96, int24 tick,,,,,) = usdStablePool.slot0();

        assertEq(position.sqrtPriceX96, sqrtPriceX96);
        assertEq(position.currentTick, tick);

        uint256 trustedSqrtPriceX96 = UniswapV3Logic._getSqrtPriceX96(priceToken0, priceToken1);
        uint256 lowerBoundSqrtPriceX96 =
            trustedSqrtPriceX96.mulDivDown(autoCompounder.LOWER_SQRT_PRICE_DEVIATION(), 1e18);
        uint256 upperBoundSqrtPriceX96 =
            trustedSqrtPriceX96.mulDivDown(autoCompounder.UPPER_SQRT_PRICE_DEVIATION(), 1e18);

        assertEq(position.lowerBoundSqrtPriceX96, lowerBoundSqrtPriceX96);
        assertEq(position.upperBoundSqrtPriceX96, upperBoundSqrtPriceX96);
    }
}
