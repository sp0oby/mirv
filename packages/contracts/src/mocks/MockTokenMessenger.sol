// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Minimal mock of Circle CCTP TokenMessenger for tests.
///         depositForBurn pulls tokens from the caller (vault) and emits
///         an event the test harness can observe. Off-chain CCTP attestation
///         + destination mint is simulated separately by tests if needed.
contract MockTokenMessenger {
    event MockDepositForBurn(uint256 amount, uint32 destinationDomain, bytes32 mintRecipient, address burnToken);

    uint64 public nextNonce;

    function depositForBurn(uint256 amount, uint32 destinationDomain, bytes32 mintRecipient, address burnToken)
        external
        returns (uint64 nonce)
    {
        // Real CCTP pulls + burns tokens. We pull and "burn" by leaving them in this contract.
        IERC20(burnToken).transferFrom(msg.sender, address(this), amount);
        nonce = nextNonce++;
        emit MockDepositForBurn(amount, destinationDomain, mintRecipient, burnToken);
    }
}
