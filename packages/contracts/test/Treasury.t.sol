// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Treasury} from "../src/Treasury.sol";
import {MockERC20} from "./helpers/TestBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract TreasuryTest is Test {
    Treasury internal treasury;
    MockERC20 internal token;
    address internal owner = makeAddr("owner");
    address internal safe  = makeAddr("safe");
    address internal alice = makeAddr("alice");

    function setUp() public {
        vm.prank(owner);
        treasury = new Treasury(safe, owner);
        token = new MockERC20("Test", "TST", 6);
    }

    // ─── Constructor ──────────────────────────────────────────────────────────

    function test_constructorSetsSafe() public view {
        assertEq(treasury.safe(), safe);
        assertEq(treasury.owner(), owner);
    }

    function test_constructorRevertsOnZeroSafe() public {
        vm.expectRevert(Treasury.ZeroAddress.selector);
        new Treasury(address(0), owner);
    }

    // ─── forwardToken ─────────────────────────────────────────────────────────

    function test_forwardTokenZeroBalanceReverts() public {
        vm.expectRevert(Treasury.ZeroAmount.selector);
        treasury.forwardToken(address(token));
    }

    function test_forwardTokenForwardsEntireBalance() public {
        token.mint(address(treasury), 1000e6);
        assertEq(token.balanceOf(safe), 0);

        treasury.forwardToken(address(token));

        assertEq(token.balanceOf(safe),             1000e6);
        assertEq(token.balanceOf(address(treasury)), 0);
    }

    function testFuzz_forwardTokenFuzz(uint256 amount) public {
        amount = bound(amount, 1, 1_000_000_000e6);
        token.mint(address(treasury), amount);
        treasury.forwardToken(address(token));
        assertEq(token.balanceOf(safe), amount);
    }

    // ─── receiveAndForward ────────────────────────────────────────────────────

    function test_receiveAndForwardPullsAndForwards() public {
        token.mint(alice, 500e6);
        vm.prank(alice);
        token.approve(address(treasury), 500e6);

        vm.prank(alice);
        treasury.receiveAndForward(address(token), 500e6);

        assertEq(token.balanceOf(safe),  500e6);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_receiveAndForwardZeroReverts() public {
        vm.expectRevert(Treasury.ZeroAmount.selector);
        treasury.receiveAndForward(address(token), 0);
    }

    // ─── forwardEth ───────────────────────────────────────────────────────────

    function test_forwardEthZeroBalanceReverts() public {
        vm.expectRevert(Treasury.ZeroAmount.selector);
        treasury.forwardEth();
    }

    function test_forwardEthForwardsEntireBalance() public {
        vm.deal(address(treasury), 1 ether);
        uint256 safeBalBefore = safe.balance;
        treasury.forwardEth();
        assertEq(safe.balance, safeBalBefore + 1 ether);
        assertEq(address(treasury).balance, 0);
    }

    // ─── setSafe ──────────────────────────────────────────────────────────────

    function test_setSafeByOwner() public {
        address newSafe = makeAddr("newSafe");
        vm.prank(owner);
        treasury.setSafe(newSafe);
        assertEq(treasury.safe(), newSafe);
    }

    function test_setSafeByNonOwnerReverts() public {
        vm.expectRevert();
        vm.prank(alice);
        treasury.setSafe(makeAddr("newSafe"));
    }

    function test_setSafeZeroReverts() public {
        vm.expectRevert(Treasury.ZeroAddress.selector);
        vm.prank(owner);
        treasury.setSafe(address(0));
    }
}
