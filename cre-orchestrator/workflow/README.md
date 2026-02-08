# CRE Workflow (CCIP Vault Orchestrator)

This workflow listens for vault events and submits CCIP messages using CRE.

## Install dependencies
```bash
bun install
```

## Configuration
- RPCs: `../project.yaml`
- Chain + address config: `./config.staging.json` or `./config.production.json`

Config keys of interest:
- `chains[]`: per-chain vault/receiver/router/LINK config
- `preflight`: whether to check LINK + token balances before sending
- `extraArgsGasLimit`: CCIP receiver gas limit (null = CCIP default)
- `writeGasLimit`: gas limit for CRE `writeReport` calls

## Simulate
Run from `cre-orchestrator/` so the CLI can find `project.yaml`:

```bash
cre workflow simulate ./workflow --target=staging-settings --broadcast
```

You will be prompted to select a chain trigger and provide a tx hash + 0-based event index for the log you want to replay.

## Events handled
- `DepositRequested`
- `WithdrawRequested`
- `WithdrawExecutionRequested`
