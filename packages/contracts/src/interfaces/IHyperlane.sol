// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Hyperlane Mailbox — permissionless cross-chain messaging
/// @dev Mailbox addresses must be verified at https://docs.hyperlane.xyz before deploy
interface IMailbox {
    /// @notice Dispatch a message to a remote chain
    /// @param destinationDomain Hyperlane domain ID of the destination chain
    /// @param recipientAddress 32-byte address of the recipient contract
    /// @param messageBody Arbitrary bytes payload (<= 1kb recommended)
    /// @return messageId Unique identifier for the dispatched message
    function dispatch(uint32 destinationDomain, bytes32 recipientAddress, bytes calldata messageBody)
        external
        payable
        returns (bytes32 messageId);

    /// @notice Quote the ETH fee required to dispatch a message (does not send)
    function quoteDispatch(uint32 destinationDomain, bytes32 recipientAddress, bytes calldata messageBody)
        external
        view
        returns (uint256 fee);

    /// @notice Hyperlane domain ID of this chain's mailbox
    function localDomain() external view returns (uint32);
}

/// @notice Implement this interface to receive Hyperlane messages
interface IMessageRecipient {
    /// @param origin Hyperlane domain ID of the source chain
    /// @param sender 32-byte address of the sender on the origin chain
    /// @param message Raw message bytes dispatched by the sender
    function handle(uint32 origin, bytes32 sender, bytes calldata message) external payable;
}
