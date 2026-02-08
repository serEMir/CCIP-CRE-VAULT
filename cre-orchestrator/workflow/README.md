# CRE Workflow (CCIP Vault Orchestrator)

This workflow listens for vault events and submits CCIP messages using CRE.

## Install dependencies
```bash
bun install
```

## Configuration
- RPCs: `../project.yaml`
- Chain + address config: `./config.staging.json` or `./config.production.json`

## Simulate
Run from `cre-orchestrator/` so the CLI can find `project.yaml`:

```bash
cre workflow simulate ./workflow --target=staging-settings --broadcast
```

You will be prompted to select a chain trigger and provide a tx hash + event index for the log you want to replay.
