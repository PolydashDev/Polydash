#!/usr/bin/env bash
# Installs Solidity dependencies into lib/ at the exact commits Polypad was built and deployed with.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p lib

fetch() {
  local dir=$1 url=$2 rev=$3
  if [ ! -d "lib/$dir/.git" ]; then git clone --quiet "$url" "lib/$dir"; fi
  git -C "lib/$dir" fetch --quiet origin "$rev" || true
  git -C "lib/$dir" checkout --quiet "$rev"
  git -C "lib/$dir" submodule update --init --recursive --quiet
  echo "lib/$dir @ $rev"
}

fetch forge-std               https://github.com/foundry-rs/forge-std               1eea5bae12ae557d589f9f0f0edae2faa47cb262
fetch openzeppelin-contracts  https://github.com/OpenZeppelin/openzeppelin-contracts 69c8def5f222ff96f2b5beff05dfba996368aa79
fetch v4-core                 https://github.com/Uniswap/v4-core                     e50237c43811bd9b526eff40f26772152a42daba
fetch v4-periphery            https://github.com/Uniswap/v4-periphery                9969eec44cfdf07e24b41de47f40276a58401976
