/**
 * Created by Pragma Labs
 * SPDX-License-Identifier: BUSL-1.1
 */
pragma solidity 0.8.22;

import { Rebalancer } from "../../../../src/rebalancers/Rebalancer.sol";
import { Rebalancer_Fuzz_Test } from "./_Rebalancer2.fuzz.t.sol";
import { SlipstreamFixture } from "../../../../lib/accounts-v2/test/utils/fixtures/slipstream/Slipstream.f.sol";

/**
 * @notice Fuzz tests for the function "receive" of contract "Rebalancer".
 */
contract Receive_Rebalancer_Fuzz_Test is Rebalancer_Fuzz_Test {
    /* ///////////////////////////////////////////////////////////////
                              SETUP
    /////////////////////////////////////////////////////////////// */

    function setUp() public override(Rebalancer_Fuzz_Test) {
        Rebalancer_Fuzz_Test.setUp();

        SlipstreamFixture.setUp();
        deployAerodromePeriphery();
        deploySlipstream();
    }

    /*//////////////////////////////////////////////////////////////
                              TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_Revert_receive_NonPositionManager(address sender, uint256 value) public {
        vm.assume(sender != address(slipstreamPositionManager));

        deal(sender, value);

        vm.prank(sender);
        (bool success, bytes memory data) = address(rebalancer).call{ value: value }(new bytes(0));

        assertFalse(success);
        assertEq(bytes4(data), Rebalancer.OnlyPositionManager.selector);
    }

    function testFuzz_Success_receive(uint256 value) public {
        deal(address(slipstreamPositionManager), value);

        vm.prank(address(slipstreamPositionManager));
        (bool success, bytes memory data) = address(rebalancer).call{ value: value }(new bytes(0));

        assertTrue(success);
        assertEq(data, bytes(""));
    }
}
