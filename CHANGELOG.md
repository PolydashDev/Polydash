# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) · [SemVer](https://semver.org/).

## [Unreleased]
### Changed
- StakingFactory v2 (`0x904b8F5d95B593b5F4a6Dbb116b58e1d5CBe93f0`) is now source-verified on Robinhood Chain (exact match, solc 0.8.24): [Blockscout](https://robinhoodchain.blockscout.com/address/0x904b8F5d95B593b5F4a6Dbb116b58e1d5CBe93f0?tab=contract).
- Poly Agent uses the verified v2 ABI names; fixes v2 `Withdrawn(user, shares, amount)` decoding and counts `EmergencyWithdrawn` as outflow.
### Pending
- Add the v2 source to `src/` and verify the individual v2 pools.

## [1.0.0] - 2026-10-28
### Added
- `PolydashStakingFactory` and `PolydashStakingPool` v1 (deployed at `0x0aAEa47d2e7303EC5a809062eafa59e7F011D857`).
- Foundry project, unit + fuzz test suite, deploy script, CI, docs, logo and banner.
