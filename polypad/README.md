# Polypad

Token launchpad on Robinhood Chain: commitment window, bonding curve, graduation to Uniswap V4.

Network: **Robinhood Chain** (chain ID 4663) · RPC `https://rpc.mainnet.chain.robinhood.com` · Explorer [https://robinhoodchain.blockscout.com](https://robinhoodchain.blockscout.com)

**Status:** Not yet externally audited.

> Solidity source will be added in a follow-up; contracts are not yet source-verified.

## How it works

1. **Commitment window.** Users commit to a new launch through `PolydashCommitVault`.
2. **Bonding curve.** The launch (an EIP-1167 clone of `PolydashLaunch`) trades on a bonding curve.
3. **Graduation.** The launch graduates to a Uniswap V4 pool that uses `PolydashHook`.

## Contracts

| Contract | Address | Deploy tx | ABI | Notes |
| --- | --- | --- | --- | --- |
| **PolydashFactory** | [`0x2c84cfcd8d283ef750e09fbed735d67f67845db2`](https://robinhoodchain.blockscout.com/address/0x2c84cfcd8d283ef750e09fbed735d67f67845db2) | [`0x966d0bd8…`](https://robinhoodchain.blockscout.com/tx/0x966d0bd8be8e220d0f961b850d8ede49ac11ad9114669bf2e33ae3825f609ded) | [`abi/PolydashFactory.json`](abi/PolydashFactory.json) | Creates launches (clones of PolydashLaunch). |
| **PolydashLaunch** | [`0xef7684268f13bc06cb02755642ceabef422b8b70`](https://robinhoodchain.blockscout.com/address/0xef7684268f13bc06cb02755642ceabef422b8b70) | [`0x60a54314…`](https://robinhoodchain.blockscout.com/tx/0x60a54314fdade940734d8e999bc9b846f82cf155ecb8d65197d79f50b5485ff0) | [`abi/PolydashLaunch.json`](abi/PolydashLaunch.json) | Launch implementation. Each launch is an EIP-1167 clone of this address. |
| **PolydashHook** | [`0x04990e6671c98e1b43034e52366af11396d960cc`](https://robinhoodchain.blockscout.com/address/0x04990e6671c98e1b43034e52366af11396d960cc) | [`0xcfc039ca…`](https://robinhoodchain.blockscout.com/tx/0xcfc039ca3454373f97fc2e476ce643f20167527fd87c0679f61fc4d9ffa76fd8) | [`abi/PolydashHook.json`](abi/PolydashHook.json) | Uniswap V4 hook used after graduation. |
| **PolydashCommitVault** | [`0x8f125c9ec7acd52b9cd39f2a7441085559d84104`](https://robinhoodchain.blockscout.com/address/0x8f125c9ec7acd52b9cd39f2a7441085559d84104) | [`0xdd691f09…`](https://robinhoodchain.blockscout.com/tx/0xdd691f0979329d68cef3c185fd912857e402df12e739574df2c7c44d2b53074f) | [`abi/PolydashCommitVault.json`](abi/PolydashCommitVault.json) | Holds commitments during the commitment window. |
| **PolydashToken** | — | — | [`abi/PolydashToken.json`](abi/PolydashToken.json) | ERC-20 deployed per launch by the factory (no single address). |
| **BuybackRouter** | — | — | [`abi/BuybackRouter.json`](abi/BuybackRouter.json) | Not deployed. |

Each deployed address above was checked with `eth_getCode` on the Robinhood Chain RPC on 2026-10-28 and has contract code (Factory 13704 bytes, Launch 10649 bytes, Hook 10005 bytes, CommitVault 5357 bytes).

### Constructor arguments

- `PolydashFactory`: `0x9a21c75aC263cC43125E70200636f6397f8776d0`, `0xEf7684268f13BC06CB02755642CeAbEf422b8B70`, `0x9a21c75aC263cC43125E70200636f6397f8776d0`
- `PolydashHook`: `0x8366a39CC670B4001A1121B8F6A443A643e40951`, `0x2C84cFCD8d283EF750E09Fbed735d67F67845dB2`
- `PolydashCommitVault`: `0x2C84cFCD8d283EF750E09Fbed735d67F67845dB2`

## Compiler settings

`solc 0.8.26`, optimizer enabled (200 runs), `via_ir = true`, EVM `cancun`, `bytecode_hash = none`.

## Files

- [`deployments.json`](deployments.json): full manifest (addresses, deploy txs, constructor args, compiler settings, ABIs).
- [`abi/`](abi): one ABI file per contract.
