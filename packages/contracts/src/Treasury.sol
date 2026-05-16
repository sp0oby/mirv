// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title Treasury
/// @notice Thin fee-routing contract. All collected fees are forwarded to the
///         Gnosis Safe (`safe`). Holds no funds long-term.
/// @dev Immutable — no upgrade mechanism. Replace via MirrorVault owner update.
contract Treasury is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── Errors ─────────────────────────────────────────────────────────────
    error ZeroAddress();
    error ZeroAmount();
    error EthTransferFailed();

    // ─── Events ─────────────────────────────────────────────────────────────
    event SafeUpdated(address indexed oldSafe, address indexed newSafe);
    event FeeForwarded(address indexed token, address indexed to, uint256 amount);
    event EthForwarded(address indexed to, uint256 amount);

    // ─── State ───────────────────────────────────────────────────────────────
    /// @notice Gnosis Safe that receives all forwarded fees
    address public safe;

    // ─── Constructor ─────────────────────────────────────────────────────────
    /// @param _safe     Gnosis Safe address
    /// @param _owner    Contract owner (multisig recommended)
    constructor(address _safe, address _owner) Ownable(_owner) {
        if (_safe == address(0)) revert ZeroAddress();
        safe = _safe;
    }

    // ─── External ────────────────────────────────────────────────────────────

    /// @notice Forward any ERC-20 balance held by this contract to the Safe.
    ///         Called by MirrorVault after each harvest.
    /// @param token ERC-20 token to forward
    function forwardToken(address token) external nonReentrant {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal == 0) revert ZeroAmount();
        IERC20(token).safeTransfer(safe, bal);
        emit FeeForwarded(token, safe, bal);
    }

    /// @notice Forward a specific amount of ERC-20 directly from the caller.
    ///         Caller must have approved this contract first.
    /// @param token  ERC-20 token
    /// @param amount Amount to pull from caller and forward to Safe
    function receiveAndForward(address token, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        IERC20(token).safeTransferFrom(msg.sender, safe, amount);
        emit FeeForwarded(token, safe, amount);
    }

    /// @notice Forward any ETH held here to the Safe
    function forwardEth() external nonReentrant {
        uint256 bal = address(this).balance;
        if (bal == 0) revert ZeroAmount();
        (bool ok,) = safe.call{value: bal}("");
        if (!ok) revert EthTransferFailed();
        emit EthForwarded(safe, bal);
    }

    // ─── Admin ───────────────────────────────────────────────────────────────

    /// @notice Update the destination Safe address
    /// @param newSafe New Gnosis Safe address
    function setSafe(address newSafe) external onlyOwner {
        if (newSafe == address(0)) revert ZeroAddress();
        emit SafeUpdated(safe, newSafe);
        safe = newSafe;
    }

    receive() external payable {}
}
