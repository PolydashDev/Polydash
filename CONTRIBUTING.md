# Contributing

1. Fork and branch from `main` (`feat/…`, `fix/…`).
2. `git submodule update --init --recursive`
3. Make changes with tests, then run:
   ```bash
   forge fmt && forge build && forge test
   ```
4. Use [Conventional Commits](https://www.conventionalcommits.org/) (`feat:`, `fix:`, `test:`, `docs:`, `ci:`, `chore:`).
5. Open a PR using the template. CI must be green.

**Notes**
- `src/` v1 files mirror the deployed bytecode and are excluded from `forge fmt`. New behaviour goes into new versions, not edits to v1.
- Never commit `.env`, private keys or keystores.
- Security issues: follow [SECURITY.md](SECURITY.md), not public issues.
