// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title MirrorFactory
/// @notice Cross-chain pair registry for mirv. Issues chain-independent
///         `canonicalPairId` values and records local-chain token + hook
///         addresses for each canonical pair on each Hyperlane domain.
///
/// @dev v4 design: the Factory is pure registry. Hook + Vault contracts for
///      a new pair are deployed via standalone scripts (see Deploy.s.sol /
///      DeployBase). After deploys, owner calls `registerLocalPair` to slot
///      the pair into the registry. This keeps Factory under the EVM 24576-byte
///      contract size limit (embedding MirrorHook + MirrorVault init_code blew
///      it past the limit in earlier drafts) AND lets per-chain deploy scripts
///      remain idiomatic forge scripts rather than complex factory calls.
///
/// @dev Permissionless pair qualification (>= $500k TVL, >= $100k daily volume
///      on all enabled chains) is enforced off-chain by agents before they
///      trigger the deploy sequence — the on-chain registry only records
///      deployments, it doesn't gate them.
contract MirrorFactory is Ownable {
    // ─── Errors ─────────────────────────────────────────────────────────────
    error PairNotRegistered();
    error CanonicalAlreadyRegistered();
    error LocalPairAlreadyRegistered();
    error EmptyName();
    error ZeroAddress();
    error NotAuthorizedAgent();
    error TokensOutOfOrder();

    // ─── Events ─────────────────────────────────────────────────────────────
    event CanonicalPairRegistered(bytes32 indexed canonicalId, string name, uint24 fee, int24 tickSpacing);
    event LocalPairRegistered(
        bytes32 indexed canonicalId, uint32 indexed hyperlaneDomain, address token0, address token1, address hook
    );
    event AgentAuthorizationUpdated(address indexed agent, bool authorized);

    // ─── Types ───────────────────────────────────────────────────────────────
    struct CanonicalPair {
        string name; // human-readable, e.g. "ETH-USDC-V1"
        uint24 fee; // V4 fee tier
        int24 tickSpacing; // V4 tick spacing
        bool registered;
    }

    struct LocalPair {
        address token0;
        address token1;
        address hook;
        bool registered;
    }

    // ─── State ───────────────────────────────────────────────────────────────

    /// @dev "ETH-USDC-V1" → canonical id (keccak256(name, fee, tickSpacing))
    mapping(string => bytes32) public canonicalIdByName;
    /// @dev canonical id → metadata
    mapping(bytes32 => CanonicalPair) public canonicalPairs;
    /// @dev canonical id → on which Hyperlane domain → local token + hook addresses
    mapping(bytes32 => mapping(uint32 => LocalPair)) public localPairs;
    mapping(address => bool) public authorizedAgents;

    /// @dev All canonical ids issued (for enumeration)
    bytes32[] public allCanonicalIds;

    // ─── Constructor ─────────────────────────────────────────────────────────
    /// @param _owner Owner / admin who registers pairs (multisig recommended at mainnet)
    constructor(address _owner) Ownable(_owner) {}

    // ─── Canonical pair registry ─────────────────────────────────────────────

    /// @notice Issue a chain-independent canonical id for a logical pair.
    ///         Every chain's MirrorHook for this pair uses the same canonical id.
    function registerCanonicalPair(string calldata name, uint24 fee, int24 tickSpacing)
        external
        onlyOwner
        returns (bytes32 canonicalId)
    {
        if (bytes(name).length == 0) revert EmptyName();
        if (canonicalIdByName[name] != bytes32(0)) revert CanonicalAlreadyRegistered();

        canonicalId = keccak256(abi.encodePacked(name, fee, tickSpacing));
        canonicalIdByName[name] = canonicalId;
        canonicalPairs[canonicalId] = CanonicalPair({name: name, fee: fee, tickSpacing: tickSpacing, registered: true});
        allCanonicalIds.push(canonicalId);

        emit CanonicalPairRegistered(canonicalId, name, fee, tickSpacing);
    }

    /// @notice Link a canonical pair to its local-chain token + hook addresses on
    ///         a specific Hyperlane domain. Lets us track which deployed hook on
    ///         which chain corresponds to the same logical pair, so new chains
    ///         can be slotted in via this admin tx without redeploying anything.
    function registerLocalPair(
        bytes32 canonicalId,
        uint32 hyperlaneDomain,
        address token0,
        address token1,
        address hook
    ) external onlyOwner {
        if (!canonicalPairs[canonicalId].registered) revert PairNotRegistered();
        if (token0 >= token1) revert TokensOutOfOrder();
        if (token0 == address(0) || hook == address(0)) revert ZeroAddress();
        if (localPairs[canonicalId][hyperlaneDomain].registered) revert LocalPairAlreadyRegistered();

        localPairs[canonicalId][hyperlaneDomain] =
            LocalPair({token0: token0, token1: token1, hook: hook, registered: true});

        emit LocalPairRegistered(canonicalId, hyperlaneDomain, token0, token1, hook);
    }

    // ─── View ─────────────────────────────────────────────────────────────────

    function canonicalPairCount() external view returns (uint256) {
        return allCanonicalIds.length;
    }

    function getLocalPair(bytes32 canonicalId, uint32 hyperlaneDomain) external view returns (LocalPair memory) {
        return localPairs[canonicalId][hyperlaneDomain];
    }

    // ─── Admin ───────────────────────────────────────────────────────────────

    function setAgentAuthorization(address agent, bool authorized) external onlyOwner {
        authorizedAgents[agent] = authorized;
        emit AgentAuthorizationUpdated(agent, authorized);
    }
}
