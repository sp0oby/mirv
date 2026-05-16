// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MirrorFactory} from "../src/MirrorFactory.sol";

/// @notice MirrorFactory admin + access-control tests.
///         deployPair() success path tested via fork tests (TODO — needs real PoolManager
///         and pre-mined hook salt).
contract MirrorFactoryTest is Test {
    MirrorFactory internal factory;

    address internal owner       = makeAddr("owner");
    address internal agent       = makeAddr("agent");
    address internal alice       = makeAddr("alice");
    address internal poolManager = makeAddr("poolManager");
    address internal mailbox     = makeAddr("mailbox");
    address internal pyth        = makeAddr("pyth");
    address internal treasury    = makeAddr("treasury");

    function setUp() public {
        factory = new MirrorFactory(poolManager, mailbox, pyth, treasury, owner);
    }

    // ─── Constructor ──────────────────────────────────────────────────────────

    function test_constructorStoresArgs() public view {
        assertEq(address(factory.poolManager()), poolManager);
        assertEq(factory.mailbox(),              mailbox);
        assertEq(factory.pyth(),                 pyth);
        assertEq(factory.treasury(),             treasury);
        assertEq(factory.owner(),                owner);
    }

    function test_constructorRevertsOnZeroAddresses() public {
        vm.expectRevert(MirrorFactory.ZeroAddress.selector);
        new MirrorFactory(address(0), mailbox, pyth, treasury, owner);

        vm.expectRevert(MirrorFactory.ZeroAddress.selector);
        new MirrorFactory(poolManager, address(0), pyth, treasury, owner);

        vm.expectRevert(MirrorFactory.ZeroAddress.selector);
        new MirrorFactory(poolManager, mailbox, address(0), treasury, owner);

        vm.expectRevert(MirrorFactory.ZeroAddress.selector);
        new MirrorFactory(poolManager, mailbox, pyth, address(0), owner);
    }

    // ─── Pair tracking ────────────────────────────────────────────────────────

    function test_pairCountStartsAtZero() public view {
        assertEq(factory.pairCount(), 0);
    }

    function test_getPairReturnsEmptyForUnknown() public view {
        MirrorFactory.DeployedPair memory p = factory.getPair(keccak256("nonexistent"));
        assertEq(p.hook,        address(0));
        assertEq(p.vault,       address(0));
        assertEq(p.token0,      address(0));
        assertEq(p.token1,      address(0));
        assertEq(p.deployedAt,  0);
    }

    // ─── Agent authorization ──────────────────────────────────────────────────

    function test_setAgentAuthorizationByOwner() public {
        assertFalse(factory.authorizedAgents(agent));
        vm.prank(owner);
        factory.setAgentAuthorization(agent, true);
        assertTrue(factory.authorizedAgents(agent));

        vm.prank(owner);
        factory.setAgentAuthorization(agent, false);
        assertFalse(factory.authorizedAgents(agent));
    }

    function test_setAgentAuthorizationByNonOwnerReverts() public {
        vm.expectRevert();
        vm.prank(alice);
        factory.setAgentAuthorization(agent, true);
    }

    // ─── deployPair access control ────────────────────────────────────────────

    function test_deployPairUnauthorizedReverts() public {
        vm.expectRevert(MirrorFactory.NotAuthorizedAgent.selector);
        vm.prank(alice);
        factory.deployPair(
            makeAddr("token0"),
            makeAddr("token1"),
            makeAddr("chainlink"),
            keccak256("pyth-feed"),
            bytes32(uint256(123)),
            3000,
            int24(60)
        );
    }

    function test_deployPairZeroTokenReverts() public {
        vm.prank(owner);
        factory.setAgentAuthorization(agent, true);

        vm.expectRevert(MirrorFactory.ZeroAddress.selector);
        vm.prank(agent);
        factory.deployPair(
            address(0),
            makeAddr("token1"),
            makeAddr("chainlink"),
            keccak256("pyth-feed"),
            bytes32(uint256(123)),
            3000,
            int24(60)
        );
    }
}
