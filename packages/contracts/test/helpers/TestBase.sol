// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MirrorVault} from "../../src/MirrorVault.sol";
import {Treasury} from "../../src/Treasury.sol";

/// @notice Minimal ERC20 for tests (6-decimal USDC-like)
contract MockERC20 is ERC20 {
    uint8 private _decimals;
    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }
    function decimals() public view override returns (uint8) { return _decimals; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/// @notice Vault + Treasury test scaffolding.
///         MirrorHook tests live in a separate fork-test suite (require V4 PoolManager
///         + CREATE2 hook address mining — see audits/mirror-hook-fork-tests.md).
abstract contract TestBase is Test {
    address internal owner    = makeAddr("owner");
    address internal agent    = makeAddr("agent");
    address internal alice    = makeAddr("alice");
    address internal bob      = makeAddr("bob");
    address internal safe     = makeAddr("safe");

    MockERC20  internal token0; // 6 decimals (USDC-like)
    MirrorVault internal vault;
    Treasury    internal treasury;

    function setUp() public virtual {
        token0 = new MockERC20("USDC Mock", "USDC", 6);

        vm.prank(owner);
        treasury = new Treasury(safe, owner);

        vm.prank(owner);
        vault = new MirrorVault(
            IERC20(address(token0)),
            address(treasury),
            owner,
            "mirv Test Vault",
            "mirvTEST"
        );

        vm.prank(owner);
        vault.setAgentAuthorization(agent, true);

        token0.mint(alice, 1_000_000e6);
        token0.mint(bob,   1_000_000e6);
    }

    function _dealTokens(address to, uint256 amt) internal {
        token0.mint(to, amt);
    }

    function _approveVault(address user, uint256 amount) internal {
        vm.prank(user);
        token0.approve(address(vault), amount);
    }
}
