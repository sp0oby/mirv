// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IMirrorHookQuoter} from "../src/interfaces/IMirrorHookQuoter.sol";

/// @title ExampleRouterIntegration
/// @notice Reference implementation showing how a V4 swap router, aggregator,
///         or intent solver would integrate mirv's cross-chain depth primitive
///         into their quote path.
///
/// @dev    This is NOT deployed — it's example code for integrators. Copy the
///         pattern below into your quoter / routing logic.
///
/// @dev    The integration is one external view call. If the pool is mirv-hooked,
///         you get the full cross-chain depth picture in one struct. If it's a
///         non-mirv pool, you fall back to your normal single-chain quote.
contract ExampleRouterIntegration {
    /// @notice Decide whether to route through a mirv pool, using mirv's
    ///         on-chain cross-chain depth primitive.
    /// @param  mirvHook    Address of the MirrorHook attached to the pool you
    ///                     might route through.
    /// @param  poolId      The V4 PoolId.
    /// @param  amountInUsd USD value of the swap the router is quoting.
    /// @return shouldRoute       True if mirv's coordinated depth makes us a
    ///                           competitive route for this size.
    /// @return effectiveDepthUsd The depth a router can think of itself as
    ///                           having access to via mirv's coordination
    ///                           (local + cross-chain combined).
    function shouldRouteThroughMirv(
        address mirvHook,
        bytes32 poolId,
        uint256 amountInUsd
    ) external view returns (bool shouldRoute, uint256 effectiveDepthUsd) {
        IMirrorHookQuoter.CrossChainQuote memory q =
            IMirrorHookQuoter(mirvHook).quoteCrossChainPool(poolId);

        // 1. Bail if the quote is unreliable (hook paused, etc.)
        if (!q.reliable) return (false, 0);

        // 2. Bail if mirv's pool is dust relative to the swap. A router
        //    shouldn't route a large swap through a pool whose depth is
        //    smaller than the swap itself — slippage would be brutal.
        if (q.localDepthUsd < amountInUsd * 5) return (false, q.totalCrossChainDepthUsd);

        // 3. The cross-chain advantage: how does the SISTER chain's depth
        //    compare? If our pool is materially shallower than a sister, the
        //    router could consider a cross-chain swap (your routing logic
        //    decides what to do — execute on the deeper side, or split).
        //    crossChainAdvantageBps:
        //      > 10000 → we're deeper here
        //      < 10000 → a sister is deeper
        bool sisterDeeper = q.crossChainAdvantageBps < 10_000;

        // 4. Combined depth — what mirv's coordination gives the router
        //    access to vs a single-chain LP.
        effectiveDepthUsd = q.totalCrossChainDepthUsd;
        shouldRoute = !sisterDeeper && effectiveDepthUsd >= amountInUsd * 5;
    }

    /// @notice Get the best chain to route a swap through, given mirv's
    ///         coordinated depth. Useful for cross-chain intent solvers.
    /// @param  mirvHook Address of the MirrorHook attached to the pool.
    /// @param  poolId   The V4 PoolId.
    /// @return bestDomain       Hyperlane domain ID of the chain with most depth
    ///                          for this pool (0 means "this chain wins").
    /// @return bestDepthUsd     Depth on that chain.
    function findDeepestChain(
        address mirvHook,
        bytes32 poolId
    ) external view returns (uint32 bestDomain, uint256 bestDepthUsd) {
        IMirrorHookQuoter.CrossChainQuote memory q =
            IMirrorHookQuoter(mirvHook).quoteCrossChainPool(poolId);

        bestDepthUsd = q.localDepthUsd;
        bestDomain   = 0; // 0 = "this chain is deepest"

        for (uint256 i; i < q.sisterChainsCount; ++i) {
            if (q.sisterDepthsUsd[i] > bestDepthUsd) {
                bestDepthUsd = q.sisterDepthsUsd[i];
                bestDomain   = q.sisterDomainIds[i];
            }
        }
    }
}
