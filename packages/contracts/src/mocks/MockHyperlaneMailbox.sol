// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IMailbox, IMessageRecipient} from "../interfaces/IHyperlane.sol";

/// @title MockHyperlaneMailbox
/// @notice Test-only mailbox that emits queueable Dispatch events and exposes a
///         `deliver()` function for off-chain relay daemons (or in-process tests)
///         to call on the destination chain.
///
/// @dev DO NOT DEPLOY TO MAINNET. This skips ISM verification entirely.
///      Used by:
///        - scripts/mock-hyperlane-relay.sh (bash daemon between Anvil forks)
///        - integration tests for cross-chain message flow
contract MockHyperlaneMailbox is IMailbox {
    uint32 private immutable _localDomain;

    /// @notice Counter for unique message IDs
    uint256 public messageCount;

    /// @notice Pending messages indexed by ID — relay daemon reads via logs, then calls deliver()
    event Dispatch(
        uint256 indexed messageIndex,
        uint32 destinationDomain,
        bytes32 indexed recipient,
        bytes32 indexed sender,
        bytes message
    );

    /// @notice Emitted when deliver() successfully called recipient.handle()
    event Delivered(uint32 indexed origin, bytes32 indexed sender, bytes32 indexed recipient);

    /// @notice Emitted when recipient.handle() reverted (application-layer failure).
    ///         The mock catches reverts so the relay daemon can continue processing.
    event DeliveryFailed(uint32 indexed origin, bytes32 indexed sender, bytes32 indexed recipient, bytes reason);

    constructor(uint32 localDomain_) {
        _localDomain = localDomain_;
    }

    function localDomain() external view override returns (uint32) {
        return _localDomain;
    }

    /// @notice Mock: always returns 0 — no fee charged in tests
    function quoteDispatch(uint32, bytes32, bytes calldata)
        external
        pure
        override
        returns (uint256)
    {
        return 0;
    }

    /// @notice Records the dispatch and emits an event for the relay daemon
    function dispatch(
        uint32 destinationDomain,
        bytes32 recipient,
        bytes calldata messageBody
    ) external payable override returns (bytes32 messageId) {
        bytes32 sender = bytes32(uint256(uint160(msg.sender)));
        messageId = keccak256(abi.encode(messageCount, destinationDomain, recipient, sender, messageBody));
        emit Dispatch(messageCount, destinationDomain, recipient, sender, messageBody);
        messageCount++;
    }

    /// @notice Called on the destination chain by the relay daemon to deliver a message
    /// @param origin       Source chain's Hyperlane domain ID
    /// @param sender       Source sender as bytes32 (taken from the source Dispatch event)
    /// @param recipient    Destination contract that implements IMessageRecipient
    /// @param messageBody  Raw payload bytes
    function deliver(
        uint32 origin,
        bytes32 sender,
        bytes32 recipient,
        bytes calldata messageBody
    ) external payable {
        address recipientAddr = address(uint160(uint256(recipient)));
        try IMessageRecipient(recipientAddr).handle{value: msg.value}(origin, sender, messageBody) {
            emit Delivered(origin, sender, recipient);
        } catch (bytes memory reason) {
            // Application-layer revert (e.g. pool not initialized, invalid params)
            // — emit so the relay daemon can see why delivery failed without halting.
            emit DeliveryFailed(origin, sender, recipient, reason);
        }
    }
}
