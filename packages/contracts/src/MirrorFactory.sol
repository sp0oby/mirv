// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {MirrorHook} from "./MirrorHook.sol";
import {MirrorVault} from "./MirrorVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title MirrorFactory
/// @notice Permissionless factory for deploying new mirrored V4 pool pairs.
///         A pair qualifies when it has >= $500k TVL AND >= $100k daily volume
///         on ALL three chains. Agents verify this off-chain and call `deployPair`.
///
/// @dev The factory does NOT mine hook addresses — that must be done off-chain via
///      MineHookAddress.s.sol before calling deployPair. Pass the pre-computed salt.
contract MirrorFactory is Ownable {

    // ─── Errors ─────────────────────────────────────────────────────────────
    error PairAlreadyDeployed();
    error ZeroAddress();
    error NotAuthorizedAgent();

    // ─── Events ─────────────────────────────────────────────────────────────
    event PairDeployed(
        bytes32 indexed pairId,
        address hook,
        address vault,
        address token0,
        address token1
    );
    event AgentAuthorizationUpdated(address indexed agent, bool authorized);

    // ─── Types ───────────────────────────────────────────────────────────────
    struct DeployedPair {
        address hook;
        address vault;
        address token0;
        address token1;
        uint256 deployedAt;
    }

    // ─── State ───────────────────────────────────────────────────────────────
    IPoolManager public immutable poolManager;
    address       public immutable mailbox;
    address       public immutable pyth;
    address       public immutable treasury;

    mapping(bytes32 => DeployedPair) public deployedPairs;
    mapping(address => bool)         public authorizedAgents;

    /// @dev Pairs indexed for enumeration
    bytes32[] public allPairIds;

    // ─── Constructor ─────────────────────────────────────────────────────────
    constructor(
        address _poolManager,
        address _mailbox,
        address _pyth,
        address _treasury,
        address _owner
    ) Ownable(_owner) {
        if (_poolManager == address(0) || _mailbox == address(0) ||
            _pyth == address(0) || _treasury == address(0)) revert ZeroAddress();
        poolManager = IPoolManager(_poolManager);
        mailbox     = _mailbox;
        pyth        = _pyth;
        treasury    = _treasury;
    }

    // ─── Deploy ───────────────────────────────────────────────────────────────

    /// @notice Deploy a new MirrorHook + MirrorVault for a token pair.
    ///         Caller must have pre-mined a hook address with correct permission bits.
    ///
    /// @param token0           Address of token0 (must be < token1 for V4 ordering)
    /// @param token1           Address of token1
    /// @param chainlinkFeed    Chainlink price feed for the pair
    /// @param pythFeedId       Pyth price feed ID
    /// @param hookSalt         CREATE2 salt to deploy MirrorHook at the mined address
    /// @param feeTier          V4 fee tier (e.g. 3000 = 0.3%)
    /// @param tickSpacing      Tick spacing matching the fee tier
    function deployPair(
        address token0,
        address token1,
        address chainlinkFeed,
        bytes32 pythFeedId,
        bytes32 hookSalt,
        uint24  feeTier,
        int24   tickSpacing
    ) external returns (address hook, address vault) {
        if (!authorizedAgents[msg.sender]) revert NotAuthorizedAgent();
        if (token0 == address(0) || token1 == address(0)) revert ZeroAddress();

        bytes32 pairId = keccak256(abi.encode(token0, token1));
        if (deployedPairs[pairId].hook != address(0)) revert PairAlreadyDeployed();

        // Deploy MirrorHook via CREATE2 using pre-mined salt
        hook = address(new MirrorHook{salt: hookSalt}(
            poolManager,
            mailbox,
            pyth,
            chainlinkFeed,
            pythFeedId,
            owner()
        ));

        // Build vault name/symbol from token metadata
        string memory sym0 = IERC20Metadata(token0).symbol();
        string memory sym1 = IERC20Metadata(token1).symbol();
        string memory vaultName   = string.concat("Mirror ", sym0, "/", sym1, " Vault");
        string memory vaultSymbol = string.concat("mirv", sym0, "-", sym1);

        // Deploy MirrorVault with token0 as the primary deposit asset
        vault = address(new MirrorVault(
            IERC20(token0),
            treasury,
            owner(),
            vaultName,
            vaultSymbol
        ));

        // Initialize the V4 pool
        PoolKey memory key = PoolKey({
            currency0:   Currency.wrap(token0),
            currency1:   Currency.wrap(token1),
            fee:         feeTier,
            tickSpacing: tickSpacing,
            hooks:       IHooks(hook)
        });
        poolManager.initialize(key, 79228162514264337593543950336); // sqrtPriceX96 = 1.0

        deployedPairs[pairId] = DeployedPair(hook, vault, token0, token1, block.timestamp);
        allPairIds.push(pairId);

        emit PairDeployed(pairId, hook, vault, token0, token1);
    }

    // ─── View ─────────────────────────────────────────────────────────────────

    function pairCount() external view returns (uint256) { return allPairIds.length; }

    function getPair(bytes32 pairId) external view returns (DeployedPair memory) {
        return deployedPairs[pairId];
    }

    // ─── Admin ───────────────────────────────────────────────────────────────

    function setAgentAuthorization(address agent, bool authorized) external onlyOwner {
        authorizedAgents[agent] = authorized;
        emit AgentAuthorizationUpdated(agent, authorized);
    }
}
