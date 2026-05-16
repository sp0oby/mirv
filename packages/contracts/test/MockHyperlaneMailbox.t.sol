// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockHyperlaneMailbox} from "../src/mocks/MockHyperlaneMailbox.sol";
import {IMessageRecipient} from "../src/interfaces/IHyperlane.sol";

/// @notice Isolated unit tests for the mock Hyperlane mailbox.
///         Verifies dispatch + deliver mechanics independent of mirv's contracts.
contract MockHyperlaneMailboxTest is Test {
    MockHyperlaneMailbox internal baseMailbox;
    MockHyperlaneMailbox internal ethMailbox;
    TestRecipient        internal recipient;
    RevertingRecipient   internal badRecipient;

    address internal alice = makeAddr("alice");

    function setUp() public {
        baseMailbox  = new MockHyperlaneMailbox(8453);
        ethMailbox   = new MockHyperlaneMailbox(1);
        recipient    = new TestRecipient();
        badRecipient = new RevertingRecipient();
    }

    function test_localDomain() public view {
        assertEq(baseMailbox.localDomain(), 8453);
        assertEq(ethMailbox.localDomain(),  1);
    }

    function test_quoteDispatchAlwaysZero() public view {
        assertEq(baseMailbox.quoteDispatch(1, bytes32(0), hex"deadbeef"), 0);
    }

    function test_dispatchEmitsEvent() public {
        bytes32 recipientB32 = bytes32(uint256(uint160(address(recipient))));
        bytes memory msgBody = abi.encode("hello mainnet");

        vm.recordLogs();
        vm.prank(alice);
        bytes32 msgId = baseMailbox.dispatch(1, recipientB32, msgBody);

        assertTrue(msgId != bytes32(0));
        assertEq(baseMailbox.messageCount(), 1);

        // Verify a Dispatch event fired
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        bytes32 sig = keccak256("Dispatch(uint256,uint32,bytes32,bytes32,bytes)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == sig) { found = true; break; }
        }
        assertTrue(found, "Dispatch event must fire");
    }

    function test_deliverCallsRecipientHandle() public {
        bytes32 senderB32 = bytes32(uint256(uint160(alice)));
        bytes32 recB32    = bytes32(uint256(uint160(address(recipient))));
        bytes memory body = abi.encode("hello base");

        vm.recordLogs();
        ethMailbox.deliver(8453, senderB32, recB32, body);

        // Recipient recorded the message
        assertEq(recipient.lastOrigin(), 8453);
        assertEq(recipient.lastSender(), senderB32);
        assertEq(recipient.lastMessage(), body);

        // Delivered event fired
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        bytes32 sig = keccak256("Delivered(uint32,bytes32,bytes32)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == sig) { found = true; break; }
        }
        assertTrue(found, "Delivered event must fire");
    }

    function test_deliverCatchesRevertAndEmitsFailed() public {
        bytes32 senderB32 = bytes32(uint256(uint160(alice)));
        bytes32 recB32    = bytes32(uint256(uint160(address(badRecipient))));

        vm.recordLogs();
        ethMailbox.deliver(8453, senderB32, recB32, "");

        // Should NOT revert — failure captured in event
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool foundFailed;
        bytes32 failSig = keccak256("DeliveryFailed(uint32,bytes32,bytes32,bytes)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == failSig) { foundFailed = true; break; }
        }
        assertTrue(foundFailed, "DeliveryFailed event must fire when handle() reverts");
    }

    function test_messageCountIncrements() public {
        for (uint256 i; i < 5; ++i) {
            baseMailbox.dispatch(1, bytes32(0), "");
        }
        assertEq(baseMailbox.messageCount(), 5);
    }
}

// Imports inline since they're only used here
import {Vm} from "forge-std/Vm.sol";

contract TestRecipient is IMessageRecipient {
    uint32  public lastOrigin;
    bytes32 public lastSender;
    bytes   public lastMessage;

    function handle(uint32 origin, bytes32 sender, bytes calldata message) external payable override {
        lastOrigin  = origin;
        lastSender  = sender;
        lastMessage = message;
    }
}

contract RevertingRecipient is IMessageRecipient {
    error AlwaysReverts();
    function handle(uint32, bytes32, bytes calldata) external payable override {
        revert AlwaysReverts();
    }
}
