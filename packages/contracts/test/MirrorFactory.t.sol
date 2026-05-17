// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MirrorFactory} from "../src/MirrorFactory.sol";

/// @notice MirrorFactory admin + canonical pair registry + access-control tests.
///         deployPair() success path tested via fork tests (needs real PoolManager
///         and pre-mined hook salt).
contract MirrorFactoryTest is Test {
    MirrorFactory internal factory;

    address internal owner = makeAddr("owner");
    address internal agent = makeAddr("agent");
    address internal alice = makeAddr("alice");
    address internal poolManager = makeAddr("poolManager");
    address internal mailbox = makeAddr("mailbox");
    address internal pyth = makeAddr("pyth");
    address internal treasury = makeAddr("treasury");
    address internal cctpMessenger = makeAddr("cctpMessenger");

    function setUp() public {
        factory = new MirrorFactory(owner);
    }

    // ─── Constructor ──────────────────────────────────────────────────────────

    function test_constructorStoresOwner() public view {
        // Factory v4 is pure registry — no poolManager/mailbox/pyth/treasury/cctp deps.
        // Deployments happen via standalone scripts that register results via registerLocalPair.
        assertEq(factory.owner(), owner);
    }

    // ─── Canonical pair registry ──────────────────────────────────────────────

    function test_canonicalPairCountStartsAtZero() public view {
        assertEq(factory.canonicalPairCount(), 0);
    }

    function test_registerCanonicalPair() public {
        vm.prank(owner);
        bytes32 id = factory.registerCanonicalPair("ETH-USDC-V1", 3000, 60);
        assertEq(id, keccak256(abi.encodePacked("ETH-USDC-V1", uint24(3000), int24(60))));
        assertEq(factory.canonicalIdByName("ETH-USDC-V1"), id);
        assertEq(factory.canonicalPairCount(), 1);
    }

    function test_registerCanonicalPairRevertsOnEmptyName() public {
        vm.prank(owner);
        vm.expectRevert(MirrorFactory.EmptyName.selector);
        factory.registerCanonicalPair("", 3000, 60);
    }

    function test_registerCanonicalPairRevertsOnDuplicate() public {
        vm.prank(owner);
        factory.registerCanonicalPair("ETH-USDC-V1", 3000, 60);

        vm.prank(owner);
        vm.expectRevert(MirrorFactory.CanonicalAlreadyRegistered.selector);
        factory.registerCanonicalPair("ETH-USDC-V1", 500, 10); // different params, same name
    }

    function test_registerLocalPair() public {
        vm.prank(owner);
        bytes32 id = factory.registerCanonicalPair("ETH-USDC-V1", 3000, 60);

        address token0 = address(0x111);
        address token1 = address(0x222);
        address hook = makeAddr("hook");

        vm.prank(owner);
        factory.registerLocalPair(id, 84532, token0, token1, hook);

        MirrorFactory.LocalPair memory lp = factory.getLocalPair(id, 84532);
        assertEq(lp.token0, token0);
        assertEq(lp.token1, token1);
        assertEq(lp.hook, hook);
        assertTrue(lp.registered);
    }

    function test_registerLocalPairRevertsForUnregisteredCanonical() public {
        vm.prank(owner);
        vm.expectRevert(MirrorFactory.PairNotRegistered.selector);
        factory.registerLocalPair(keccak256("unknown"), 84532, address(0x111), address(0x222), makeAddr("hook"));
    }

    function test_registerLocalPairRevertsOnTokenOrder() public {
        vm.prank(owner);
        bytes32 id = factory.registerCanonicalPair("ETH-USDC-V1", 3000, 60);

        vm.prank(owner);
        vm.expectRevert(MirrorFactory.TokensOutOfOrder.selector);
        factory.registerLocalPair(id, 84532, address(0x222), address(0x111), makeAddr("hook"));
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

}
