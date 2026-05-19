// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IMirrorHookQuoter
/// @notice The cross-chain liquidity depth primitive routers + aggregators
///         call when quoting a swap against a mirv-hooked pool. Returns a
///         single struct containing everything a quoter needs to factor
///         mirv's coordinated cross-chain depth into routing decisions.
///
/// @dev    Any V4 router, aggregator, intent solver, or even another hook can
///         call `quoteCrossChainPool(poolId)` on a `MirrorHook` and receive
///         a sealed view of the protocol's coordinated depth. No off-chain
///         indexer required — depth across chains is on-chain and addressable
///         via this single view function.
///
/// @dev    Designed for integration patterns like:
///         - Uniswap Universal Router V4 quoter — call `quoteCrossChainPool`
///           when the router encounters a mirv-hooked pool to decide whether
///           the cross-chain coordination produces a better effective price
///           than a single-chain quote
///         - 1inch / Matcha / CowSwap solvers — same call, but feed the
///           result into the multi-route optimization
///         - Cross-chain swap UIs (Across, deBridge, LI.FI) — use the
///           sister-depth data to pick the cheapest destination chain
interface IMirrorHookQuoter {
    /// @notice Per-quote return shape. Compact enough that calling this from
    ///         a router quote path is < 10k gas. All values pre-aggregated.
    struct CrossChainQuote {
        /// @notice This chain's current depth at the active tick, USD-denominated
        ///         (18 decimals). Reads `localDepthUsd[poolId]`.
        uint256 localDepthUsd;
        /// @notice Number of sister chains currently registered for this pool's pair.
        ///         A 0 here means cross-chain coordination is not configured for this
        ///         pool — routers should treat the quote as single-chain.
        uint256 sisterChainsCount;
        /// @notice Per-sister-chain depth, USD-denominated. Aligned with `sisterDomainIds`
        ///         by index. Reads `sisterDepths[domain][canonicalPairId]`.
        uint256[] sisterDepthsUsd;
        /// @notice Hyperlane domain IDs of each sister chain. Parallel to `sisterDepthsUsd`.
        uint32[] sisterDomainIds;
        /// @notice Sum of `localDepthUsd + Σ sisterDepthsUsd`. The effective depth
        ///         available to a router that uses mirv's coordination — i.e. the
        ///         "what depth do I have access to across the mirv network?" number.
        uint256 totalCrossChainDepthUsd;
        /// @notice `localDepthUsd × MAX_BPS / max(1, sisterDepthsUsd[best sister])`.
        ///         Tells a router whether the OTHER chain has materially more depth
        ///         than this one. Above MAX_BPS (10000) means we're deeper here;
        ///         below means a sister is deeper and a cross-chain route might
        ///         be better. Returns MAX_BPS when there are no sisters configured.
        uint256 crossChainAdvantageBps;
        /// @notice Whether the quote is reliable enough to act on. False if:
        ///         - the hook is paused
        ///         - any sister's last cross-chain report exceeds the staleness window
        ///         Routers should fall back to single-chain quoting when this is false.
        bool reliable;
    }

    /// @notice Returns the cross-chain depth quote for a given V4 pool. View only,
    ///         no state changes, callable by anyone.
    /// @param  poolId The V4 PoolId — `keccak256(currency0, currency1, fee, tickSpacing, hooks)`.
    ///                Must be a pool hooked by this MirrorHook for `localDepthUsd` to be non-zero.
    /// @return q      Fully-populated quote struct. See `CrossChainQuote` for field semantics.
    function quoteCrossChainPool(bytes32 poolId) external view returns (CrossChainQuote memory q);
}
