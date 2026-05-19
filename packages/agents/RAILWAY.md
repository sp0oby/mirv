# Deploying the mirv agent to Railway

The agent is a long-running Node process. Railway runs it 24/7 with auto-restart on crash.

## One-time setup

1. **Create a Railway project** at https://railway.app — connect your GitHub.
2. **New Service → Deploy from GitHub repo** → select `sp0oby/mirv`.
3. Railway will detect `railway.json` at the repo root and use Nixpacks to install
   the workspace. The start command `yarn workspace @mirror/agents start` is set
   in that file.
4. **Settings → Service**:
   - Root Directory: leave as `/` (we run from the repo root so `yarn` finds
     all workspaces).
   - Restart Policy: `On Failure` with 10 retries (already in `railway.json`).
   - No public networking needed — this is a worker, not a web server.

## Environment variables

Paste these into Railway's **Variables** tab. Sepolia values are below; swap
to mainnet equivalents on launch.

### Required

| Variable | Value (Sepolia today) |
|---|---|
| `NETWORK` | `sepolia` |
| `AGENT_PRIVATE_KEY` | hot wallet key (your `0xDCb7…7ebA` agent EOA) |
| `ANTHROPIC_API_KEY` | your Claude API key |
| `ALCHEMY_BASE_URL` | your Base Sepolia Alchemy RPC URL |
| `ALCHEMY_MAINNET_URL` | your ETH Sepolia Alchemy RPC URL |
| `HYPERLANE_MAILBOX_BASE` | `0x6966b0E55883d49BFB24539356a2f8A673E02039` |
| `HYPERLANE_MAILBOX_MAINNET` | `0xfFAEF09B3cd11D9b20d1a19bECca54EEC2884766` |
| `MIRROR_HOOK_BASE` | `0xA059C8544E046F29C5c2A9f0dE6314964926c540` |
| `MIRROR_HOOK_MAINNET` | `0xc3233eb9C427Cc1ACA5cF2d5c5e89c668F148540` |
| `CHAINLINK_ETH_USD_BASE_SEPOLIA` | `0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1` |
| `CHAINLINK_ETH_USD_ETH_SEPOLIA` | `0x694AA1769357215DE4FAC081bf1f309aDC325306` |

### Variables with sensible defaults (set only if you need to override)

| Variable | Default |
|---|---|
| `POOL_MANAGER_BASE_SEPOLIA` | `0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408` |
| `POOL_MANAGER_ETH_SEPOLIA` | `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` |
| `STATE_VIEW_BASE_SEPOLIA` | `0x571291b572ed32ce6751a2cb2486ebee8defb9b4` |
| `STATE_VIEW_ETH_SEPOLIA` | `0xe1dd9c3fa50edb962e442f60dfbc432e24537e4c` |
| `REDIS_URL` | leave unset — history tracking auto-disables |
| `MAX_CYCLES` | unset for indefinite; set e.g. `10` for a soak test |
| `ENABLE_BNB_MONITOR` | leave unset |

### Confirming everything works

1. After deploy, check **Deployments → View Logs** in Railway.
2. You should see within ~30 seconds:
   ```
   === mirv agent swarm starting ===
   Cycle interval: 45s
   [Cycle 1] Running monitors...
   ```
3. Each cycle should produce:
   - `[monitor:base]` and `[monitor:ethereum]` lines with `depth=$X`
   - `[rebalance]` with `action=rebalance|none`
   - If `action=rebalance`: `[risk] status=green|yellow|red`
   - If risk green: `[coordinator] approved=true` and `dispatchRebalance tx: 0x…`
   - `[Cycle N] Done. maxImbalance=X.XX%`
4. The dashboard at `mirv.vercel.app/dashboard` will start showing "last
   check-in" timestamps updating every cycle, and the activity feed will
   accumulate `RebalanceDispatched` events whenever the swarm decides to act.

## Cost

A worker service on Railway runs ~$5/mo at the default plan
(0.5 vCPU, 512 MB RAM). The Anthropic API costs depend on cycle frequency:
at 45s cycles × 4 LLM calls/cycle × ~$0.01/call ≈ $7/day. Set
`CYCLE_INTERVAL_MS` higher (in `src/index.ts`) to slow it down if needed,
or wait for the x402 LLM payment migration so the vault funds the calls
directly.

## Security notes

- `AGENT_PRIVATE_KEY` is a hot wallet — Railway env vars are encrypted at
  rest, but anyone with project access can read them. Use a fresh key here,
  not your main deployer.
- The agent's worst-case damage per cycle is bounded on-chain (`R-1`: 25% of
  total assets, 60s cooldown). Even a compromised host can't drain the vault.
- Rotate the agent key periodically. The contract supports it:
  `MirrorVault.setAuthorizedAgent(oldAgent, false)` + `setAuthorizedAgent(newAgent, true)`.

## Watching it run

- **Railway logs** — live stdout from the agent
- **Frontend dashboard** — `mirv.vercel.app/dashboard` shows last check-in
- **Frontend activity** — `mirv.vercel.app/activity` shows rebalances landing
- **Block explorers** — every dispatch lands as a `RebalanceDispatched` event
  on the Base hook (or ETH hook for reverse-direction)
