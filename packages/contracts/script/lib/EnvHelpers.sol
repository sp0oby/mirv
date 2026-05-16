// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";

/// @notice Shared script helpers. Accepts private keys with or without 0x prefix.
library EnvHelpers {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev Reads a uint256 from env. Handles both "0x..." and bare-hex (no prefix) formats.
    function envPrivateKey(string memory name) internal view returns (uint256) {
        string memory raw = vm.envString(name);
        bytes memory rawBytes = bytes(raw);
        if (rawBytes.length >= 2 && rawBytes[0] == "0" && rawBytes[1] == "x") {
            return vm.parseUint(raw);
        }
        return vm.parseUint(string.concat("0x", raw));
    }
}
