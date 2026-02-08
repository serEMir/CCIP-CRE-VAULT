## Contracts

This package contains the Solidity contracts and Foundry tooling for the CCIP + CRE Unified Vault system.

**Key contracts**
- `src/UnifiedVault.sol` — vault that emits cross-chain intents and executes CCIP sends.
- `src/VaultCCIPReceiver.sol` — CCIP receiver that applies deposits/withdrawals.

## Prerequisites
- Foundry (`forge`, `cast`)
- RPC URLs for Sepolia and Base Sepolia

## Setup
1. Install submodules (run from repo root):
   - `git submodule update --init --recursive`
2. Create `contracts/.env` with RPC URLs and keys:
   - `SEPOLIA_RPC_URL=...`
   - `BASE_SEPOLIA_RPC_URL=...`
   - `ETHERSCAN_API_KEY=...`

## Build and test
1. Build:
   - `forge build`
2. Test:
   - `forge test -vvv`

## Deploy
Example (Sepolia):
```bash
forge script script/DeployVaultSystem.s.sol \
  --rpc-url $SEPOLIA_RPC_URL \
  --account $ACCOUNT \
  --broadcast \
  --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY
```

After deploy, ensure:
- `setCREForwarder(...)` is set to the Keystone forwarder address.
- `allowlistSourceChain(...)` and `allowlistSender(...)` are set on receivers.
- Vault has enough LINK for CCIP fees.

## Common operational steps
- User must approve the vault to spend the deposit token before calling `requestDeposit`.
- The vault will approve the CCIP router for LINK fees and token transfers when sending.
- Fund the vault with LINK to pay CCIP fees.

## Notes
- `UnifiedVault.onReport(bytes,bytes)` is the CRE entrypoint and is restricted to the owner or the configured forwarder.
- Receivers enforce allowlists for source chains and senders; configure them before sending messages.
