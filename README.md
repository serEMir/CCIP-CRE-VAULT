# CCIP + CRE Unified Vault

Cross-chain vault system that uses Chainlink CCIP for token movement and Chainlink CRE to build and submit CCIP messages offchain. The onchain vault emits intent events, CRE observes and builds the CCIP payload, and the CCIP receiver applies the outcome on the destination chain.

**Repo layout**
- `contracts/` — Solidity contracts and Foundry tooling.
- `cre-orchestrator/` — CRE workflow code and configs.

**Prerequisites**
- Foundry (`forge`, `cast`)
- Bun (for the CRE workflow)
- CRE CLI (`cre`)

**Quick start**
1. Clone and init submodules:
   - `git submodule update --init --recursive`
2. Build contracts:
   - `cd contracts`
   - `forge build`
3. Install workflow deps:
   - `cd ../cre-orchestrator/workflow`
   - `bun install`
4. Simulate CRE workflow:
   - `cd ..`
   - `cre workflow simulate ./workflow --target=staging-settings --broadcast`
   - Select a chain trigger and provide a tx hash + 0-based event index.

**Configuration**
- `contracts/.env` for RPCs and deploy credentials.
- `cre-orchestrator/project.yaml` for CRE RPC settings.
- `cre-orchestrator/workflow/config.*.json` for chain addresses and workflow settings.

**Dependency policy (recommended)**
- Keep `forge-std`, `openzeppelin-contracts`, and `chainlink-ccip` as submodules under `contracts/lib`.
- Do not modify submodule code directly. If a change is required, fork the dependency and update the submodule URL.

**Security**
- Do not commit `.env` files or `secrets.yaml`.

See the folder READMEs for more details.
