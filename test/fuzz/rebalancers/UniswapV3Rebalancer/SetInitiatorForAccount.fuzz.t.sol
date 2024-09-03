/**
 * Created by Pragma Labs
 * SPDX-License-Identifier: BUSL-1.1
 */
pragma solidity 0.8.22;

import { UniswapV3Rebalancer } from "../../../../src/rebalancers/uniswap-v3/UniswapV3Rebalancer.sol";
import { UniswapV3Rebalancer_Fuzz_Test } from "./_UniswapV3Rebalancer.fuzz.t.sol";

/**
 * @notice Fuzz tests for the function "setInitiatorForAccount" of contract "UniswapV3Rebalancer".
 */
contract SetInitiatorForAccount_UniswapV3Rebalancer_Fuzz_Test is UniswapV3Rebalancer_Fuzz_Test {
    /* ///////////////////////////////////////////////////////////////
                              SETUP
    /////////////////////////////////////////////////////////////// */

    function setUp() public override {
        UniswapV3Rebalancer_Fuzz_Test.setUp();
    }

    /*//////////////////////////////////////////////////////////////
                              TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_Revert_setInitiatorForAccount_NotAnAccount(address owner, address initiator, address account_)
        public
    {
        vm.assume(account_ != address(account));
        // Given : account is not an Arcadia Account
        // When : calling rebalancePosition
        // Then : it should revert
        vm.expectRevert(UniswapV3Rebalancer.NotAnAccount.selector);
        // When : A randon address calls setInitiator on the rebalancer
        vm.prank(owner);
        rebalancer.setInitiatorForAccount(initiator, account_);
    }

    function testFuzz_Success_setInitiatorForAccount(address owner, address initiator) public {
        // Given : account is a valid Arcadia Account
        // When : A randon address calls setInitiator on the rebalancer
        vm.prank(owner);
        rebalancer.setInitiatorForAccount(initiator, address(account));

        // Then : Initiator should be set for that Account
        assertEq(rebalancer.ownerToAccountToInitiator(owner, address(account)), initiator);
    }
}
