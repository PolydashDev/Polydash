'use client';

import { useQuery } from '@tanstack/react-query';
import { usePublicClient } from 'wagmi';
import { formatEther, parseAbiItem, type PublicClient } from 'viem';
import { PolydashFactoryABI, PolydashLaunchABI, PolydashTokenABI } from '@/lib/contracts/abis';
import { getFactoryAddress } from '@/lib/contracts/addresses';
import { robinhoodChain } from '@/lib/chain';
import type { LaunchToken } from '@/lib/token-types';

export const DEPLOY_BLOCK = BigInt(85405135);
const BOUGHT = parseAbiItem('event Bought(address indexed buyer, uint256 ethIn, uint256 tokensOut, uint256 platformFee, uint256 creatorFee, uint256 price)');
const SOLD = parseAbiItem('event Sold(address indexed seller, uint256 tokensIn, uint256 ethOut, uint256 platformFee, uint256 creatorFee, uint256 price)');

export function useEthPrice() {
  return useQuery({
    queryKey: ['eth-price'],
    queryFn: async () => {
      const r = await fetch('/api/eth-price');
      const j = await r.json();
      return Number(j?.price ?? 0);
    },
    staleTime: 60_000,
  });
}

const LAUNCH_FIELDS = ['token', 'creator', 'creatorFeeBps', 'phase', 'spotPrice', 'realEthRaised', 'graduationThreshold', 'tokensSold', 'curveSupply', 'totalSupply', 'virtualEth', 'launchTime', 'graduated', 'k', 'totalCommitted', 'committersLength', 'commitmentCursor'] as const;
const TOKEN_FIELDS = ['name', 'symbol', 'imageUri', 'description', 'socialLinks'] as const;

async function fetchVolumes(client: PublicClient, launches: `0x${string}`[]): Promise<Record<string, number>> {
  const vol: Record<string, number> = {};
  if (launches.length === 0) return vol;
  try {
    const [buys, sells] = await Promise.all([
      client.getLogs({ address: launches, event: BOUGHT, fromBlock: DEPLOY_BLOCK, toBlock: 'latest' }),
      client.getLogs({ address: launches, event: SOLD, fromBlock: DEPLOY_BLOCK, toBlock: 'latest' }),
    ]);
    for (const l of buys) vol[l.address.toLowerCase()] = (vol[l.address.toLowerCase()] ?? 0) + Number(formatEther(l.args.ethIn ?? BigInt(0)));
    for (const l of sells) vol[l.address.toLowerCase()] = (vol[l.address.toLowerCase()] ?? 0) + Number(formatEther(l.args.ethOut ?? BigInt(0)));
  } catch (e) {
    console.error('Failed to load trade volume logs', e);
  }
  return vol;
}

export async function fetchLaunchDetails(client: PublicClient, addrs: `0x${string}`[], ethUsd: number): Promise<LaunchToken[]> {
  if (addrs.length === 0) return [];
  const launchRes = await client.multicall({
    contracts: addrs.flatMap((a) => LAUNCH_FIELDS.map((f) => ({ address: a, abi: PolydashLaunchABI, functionName: f }))) as any,
    allowFailure: true,
  });
  const perLaunch = addrs.map((_, i) => {
    const slice = launchRes.slice(i * LAUNCH_FIELDS.length, (i + 1) * LAUNCH_FIELDS.length);
    const o: Record<string, any> = {};
    LAUNCH_FIELDS.forEach((f, j) => { o[f] = slice[j]?.status === 'success' ? slice[j].result : undefined; });
    return o;
  });
  const tokenAddrs = perLaunch.map((l) => l.token as `0x${string}` | undefined);
  const tokenRes = await client.multicall({
    contracts: tokenAddrs.flatMap((t) => TOKEN_FIELDS.map((f) => ({ address: t ?? '0x0000000000000000000000000000000000000000', abi: PolydashTokenABI, functionName: f }))) as any,
    allowFailure: true,
  });
  const vols = await fetchVolumes(client, addrs);

  return addrs.map((addr, i) => {
    const l = perLaunch[i];
    const tslice = tokenRes.slice(i * TOKEN_FIELDS.length, (i + 1) * TOKEN_FIELDS.length);
    const t: Record<string, any> = {};
    TOKEN_FIELDS.forEach((f, j) => { t[f] = tslice[j]?.status === 'success' ? tslice[j].result : undefined; });
    const zero = BigInt(0);
    const priceEth = Number(formatEther((l.spotPrice as bigint) ?? zero));
    const totalSupplyTokens = Number(formatEther((l.totalSupply as bigint) ?? zero));
    const raised = Number(formatEther((l.realEthRaised as bigint) ?? zero));
    const threshold = Number(formatEther((l.graduationThreshold as bigint) ?? zero));
    const phase = Number(l.phase ?? 0);
    const graduated = Boolean(l.graduated) || phase === 4;
    const progress = graduated ? 100 : threshold > 0 ? Math.min(100, Math.round((raised / threshold) * 1000) / 10) : 0;
    const volEth = vols[addr.toLowerCase()] ?? 0;
    return {
      launchAddress: addr,
      tokenAddress: (l.token as string) ?? '',
      name: (t.name as string) ?? 'Unknown',
      symbol: (t.symbol as string) ?? '???',
      imageUri: (t.imageUri as string) ?? '',
      description: (t.description as string) ?? '',
      creator: (l.creator as string) ?? '',
      creatorFeeBps: Number(l.creatorFeeBps ?? 0),
      curveProgress: progress,
      marketCapUsd: priceEth * totalSupplyTokens * ethUsd,
      volumeUsd: volEth * ethUsd,
      priceEth,
      ethRaised: raised,
      graduationThreshold: threshold,
      graduated,
      totalSupply: String(Math.round(totalSupplyTokens)),
      socialLinks: ((t.socialLinks as string[]) ?? []).filter(Boolean),
      createdAt: Number(l.launchTime ?? 0) * 1000,
      phase,
      launchTime: Number(l.launchTime ?? 0) * 1000,
      totalCommitted: Number(formatEther((l.totalCommitted as bigint) ?? zero)),
      committers: Number(l.committersLength ?? 0),
      commitmentCursor: Number(l.commitmentCursor ?? 0),
      virtualEthWei: String(l.virtualEth ?? 0),
      curveSupplyWei: String(l.curveSupply ?? 0),
      tokensSoldWei: String(l.tokensSold ?? 0),
      kWei: String(l.k ?? 0),
    } satisfies LaunchToken;
  });
}

/** All launches created through the factory, read live from the chain. */
export function useLaunches() {
  const client = usePublicClient({ chainId: robinhoodChain.id });
  const { data: ethUsd } = useEthPrice();
  const factory = getFactoryAddress();
  return useQuery({
    queryKey: ['launches', factory, ethUsd ?? 0],
    enabled: !!client && !!factory,
    refetchInterval: 30_000,
    queryFn: async () => {
      if (!client || !factory) return [];
      const len = (await client.readContract({ address: factory, abi: PolydashFactoryABI, functionName: 'allLaunchesLength' })) as bigint;
      const n = Number(len);
      if (n === 0) return [];
      const addrRes = await client.multicall({
        contracts: Array.from({ length: n }, (_, i) => ({ address: factory, abi: PolydashFactoryABI, functionName: 'allLaunches', args: [BigInt(i)] })) as any,
        allowFailure: true,
      });
      const addrs = addrRes.filter((r) => r.status === 'success').map((r) => r.result as `0x${string}`);
      return fetchLaunchDetails(client as PublicClient, addrs, ethUsd ?? 0);
    },
  });
}

/** A single launch by its launch contract address. */
export function useLaunch(address: string) {
  const client = usePublicClient({ chainId: robinhoodChain.id });
  const { data: ethUsd } = useEthPrice();
  const factory = getFactoryAddress();
  return useQuery({
    queryKey: ['launch', address, ethUsd ?? 0],
    enabled: !!client && !!factory && /^0x[0-9a-fA-F]{40}$/.test(address),
    refetchInterval: 15_000,
    queryFn: async () => {
      if (!client || !factory) return null;
      const ok = (await client.readContract({ address: factory, abi: PolydashFactoryABI, functionName: 'isLaunch', args: [address as `0x${string}`] })) as boolean;
      if (!ok) return null;
      const [t] = await fetchLaunchDetails(client as PublicClient, [address as `0x${string}`], ethUsd ?? 0);
      return t ?? null;
    },
  });
}

/** priceEth is the curve spot price right after the trade (emitted by the contract). */
export interface TradeRow { isBuy: boolean; trader: string; eth: number; tokens: number; priceEth: number; txHash: string; timestamp: number; }

/** All buys/sells on a launch from on-chain event logs, newest first. */
export function useTrades(address: string) {
  const client = usePublicClient({ chainId: robinhoodChain.id });
  return useQuery({
    queryKey: ['trades', address],
    enabled: !!client && /^0x[0-9a-fA-F]{40}$/.test(address),
    refetchInterval: 15_000,
    queryFn: async (): Promise<TradeRow[]> => {
      if (!client) return [];
      const a = address as `0x${string}`;
      const [buys, sells] = await Promise.all([
        client.getLogs({ address: a, event: BOUGHT, fromBlock: DEPLOY_BLOCK, toBlock: 'latest' }),
        client.getLogs({ address: a, event: SOLD, fromBlock: DEPLOY_BLOCK, toBlock: 'latest' }),
      ]);
      const rows = [
        ...buys.map((l) => ({ isBuy: true, trader: l.args.buyer ?? '', eth: Number(formatEther(l.args.ethIn ?? BigInt(0))), tokens: Number(formatEther(l.args.tokensOut ?? BigInt(0))), priceEth: Number(formatEther(l.args.price ?? BigInt(0))), txHash: l.transactionHash, block: l.blockNumber, idx: l.logIndex })),
        ...sells.map((l) => ({ isBuy: false, trader: l.args.seller ?? '', eth: Number(formatEther(l.args.ethOut ?? BigInt(0))), tokens: Number(formatEther(l.args.tokensIn ?? BigInt(0))), priceEth: Number(formatEther(l.args.price ?? BigInt(0))), txHash: l.transactionHash, block: l.blockNumber, idx: l.logIndex })),
      ].sort((x, y) => (x.block === y.block ? Number(y.idx) - Number(x.idx) : Number(y.block - x.block))).slice(0, 300);
      const blocks = Array.from(new Set(rows.map((r) => r.block)));
      const ts: Record<string, number> = {};
      await Promise.all(blocks.map(async (b) => {
        try { const blk = await client.getBlock({ blockNumber: b }); ts[b.toString()] = Number(blk.timestamp) * 1000; } catch { ts[b.toString()] = 0; }
      }));
      return rows.map((r) => ({ isBuy: r.isBuy, trader: r.trader, eth: r.eth, tokens: r.tokens, priceEth: r.priceEth, txHash: r.txHash, timestamp: ts[r.block.toString()] ?? 0 }));
    },
  });
}
