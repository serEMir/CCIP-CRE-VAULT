# CRE Orchestrator

This package contains the Chainlink CRE workflow that observes vault events and submits CCIP messages.

## Prerequisites
- CRE CLI (`cre`)
- Bun

## Setup
1. Install workflow dependencies:
   - `cd workflow`
   - `bun install`
2. Configure RPCs in `project.yaml`.
3. Configure chains in `workflow/config.staging.json` or `workflow/config.production.json`.

## Run a local simulation
Run from the `cre-orchestrator` directory so the CLI can find `project.yaml`:

```bash
cre workflow simulate ./workflow --target=staging-settings --broadcast
```

When prompted, select a chain trigger and provide a tx hash + 0-based event index for the vault log you want to replay.

## Workflow behavior
- Triggers on `DepositRequested`, `WithdrawRequested`, and `WithdrawExecutionRequested` logs.
- Builds the CCIP message offchain and calls `executeCCIPSend` on the source vault via CRE.
- Preflight checks for LINK balance and (where applicable) token balances before sending.
- Uses `writeGasLimit` from the config for CRE writes; `extraArgsGasLimit` controls CCIP receiver gas (or defaults to 200k when `null`).

## Deploy (Early Access)
Deployment requires CRE Early Access and mainnet registry setup. If enabled:

```bash
cre workflow deploy ./workflow --target=production-settings
```

## Notes
- `.env` and `secrets.yaml` should never be committed.
- The workflow reads chain addresses from `workflow/config.*.json`.
