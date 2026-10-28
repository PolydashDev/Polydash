'use client';

import dynamic from 'next/dynamic';
import { useMemo, useState } from 'react';
import { formatEther } from 'viem';
import { ArrowUpRight, Loader2 } from 'lucide-react';
import type { LaunchToken } from '@/lib/token-types';
import { useEthPrice, useTrades } from '@/lib/hooks/use-launches';
import type { McapPoint } from './line-chart-inner';
import { formatCompact as compactNum } from '@/lib/format';
import { cn } from '@/lib/utils';

const LineChartComponent = dynamic(() => import('./line-chart-inner'), {
  ssr: false,
  loading: () => <div className="h-[260px] sm:h-[340px]" />,
});

const RANGES = [
  { key: '1H', ms: 3600_000 },
  { key: '6H', ms: 6 * 3600_000 },
  { key: '24H', ms: 24 * 3600_000 },
  { key: 'All', ms: 0 },
] as const;

export function dexScreenerUrl(tokenAddress: string) {
  return `https://dexscreener.com/robinhood/${tokenAddress}`;
}

/** Market cap over time for a token on the bonding curve, built from on-chain trades. */
export function MarketCapChart({ token }: { token: LaunchToken }) {
  const { data: ethUsd } = useEthPrice();
  const { data: trades, isLoading, dataUpdatedAt } = useTrades(token.launchAddress);
  const [range, setRange] = useState<(typeof RANGES)[number]['key']>('All');
  const usd = (ethUsd ?? 0) > 0;
  const rate = usd ? (ethUsd as number) : 1;
  const unit = usd ? 'USD' : 'ETH';
  const fmt = (v: number) => (usd ? `$${compactNum(v)}` : `${compactNum(v)} ETH`);

  const { series, change } = useMemo(() => {
    const supply = Number(token.totalSupply || '0');
    const v = Number(formatEther(BigInt(token.virtualEthWei || '0')));
    const cs = Number(formatEther(BigInt(token.curveSupplyWei || '0')));
    const startPrice = cs > 0 ? v / cs : token.priceEth;
    const end = dataUpdatedAt || token.launchTime;
    const pts: McapPoint[] = [];
    if (token.launchTime) pts.push({ t: token.launchTime, mcap: startPrice * supply * rate });
    [...(trades ?? [])].reverse().forEach((tr) => {
      if (tr.timestamp && tr.priceEth > 0) pts.push({ t: tr.timestamp, mcap: tr.priceEth * supply * rate });
    });
    pts.push({ t: Math.max(end, pts[pts.length - 1]?.t ?? end), mcap: token.priceEth * supply * rate });
    const span = RANGES.find((r) => r.key === range)?.ms ?? 0;
    let s = pts;
    if (span > 0) {
      const from = end - span;
      const before = [...pts].reverse().find((p) => p.t <= from);
      s = [...(before ? [{ t: from, mcap: before.mcap }] : []), ...pts.filter((p) => p.t > from)];
    }
    if (s.length === 1) s = [{ t: s[0].t - 60_000, mcap: s[0].mcap }, s[0]];
    const first = s[0]?.mcap ?? 0;
    const last = s[s.length - 1]?.mcap ?? 0;
    return { series: s, change: first > 0 ? ((last - first) / first) * 100 : 0 };
  }, [trades, token, rate, range, dataUpdatedAt]);

  const mcap = token.priceEth * Number(token.totalSupply || '0') * rate;
  const up = change >= 0;

  return (
    <div>
      <div className="flex flex-wrap items-end justify-between gap-3 px-4 pt-4 sm:px-5 sm:pt-5">
        <div>
          <div className="text-[12px] text-white/45">Market cap</div>
          <div className="mt-0.5 flex items-baseline gap-2">
            <span className="font-mono text-[26px] sm:text-[30px] font-semibold tracking-tight">{fmt(mcap)}</span>
            <span className={cn('font-mono text-[13px] font-medium', up ? 'text-polydash-green' : 'text-[#FF5252]')}>
              {up ? '+' : ''}{change.toFixed(2)}%
            </span>
            <span className="text-[12px] text-white/35">{range === 'All' ? 'since launch' : range}</span>
          </div>
        </div>
        <div className="flex rounded-full bg-white/[0.05] p-0.5">
          {RANGES.map((r) => (
            <button
              key={r.key}
              onClick={() => setRange(r.key)}
              className={cn('rounded-full px-3 py-1 text-[12px] font-medium transition-colors', range === r.key ? 'bg-white/10 text-white' : 'text-white/45 hover:text-white')}
            >
              {r.key}
            </button>
          ))}
        </div>
      </div>
      <div className="px-1 pb-2 pt-3 sm:px-2">
        {isLoading ? (
          <div className="flex h-[260px] sm:h-[340px] items-center justify-center gap-2 text-[13px] text-white/40">
            <Loader2 className="h-4 w-4 animate-spin" /> Loading trades
          </div>
        ) : (
          <LineChartComponent data={series} unit={unit} up={up} />
        )}
      </div>
    </div>
  );
}

/** Graduated tokens trade on Uniswap V4: show market cap and send users to DexScreener for the chart. */
export function GraduatedChartPanel({ token }: { token: LaunchToken }) {
  const { data: ethUsd } = useEthPrice();
  const usd = (ethUsd ?? 0) > 0;
  const mcap = token.priceEth * Number(token.totalSupply || '0') * (usd ? (ethUsd as number) : 1);
  return (
    <div className="flex flex-col items-start justify-between gap-5 p-5 sm:flex-row sm:items-center sm:p-6">
      <div>
        <div className="text-[12px] text-white/45">Market cap at graduation</div>
        <div className="mt-0.5 font-mono text-[26px] sm:text-[30px] font-semibold tracking-tight">
          {usd ? `$${compactNum(mcap)}` : `${compactNum(mcap)} ETH`}
        </div>
        <p className="mt-1.5 max-w-md text-[13px] text-white/50">
          This token has graduated and now trades on Uniswap V4. Live price and chart are on DexScreener.
        </p>
      </div>
      <a
        href={dexScreenerUrl(token.tokenAddress)}
        target="_blank"
        rel="noopener noreferrer"
        className="inline-flex h-9 shrink-0 items-center gap-1.5 rounded-full bg-polydash-green px-4 text-[13px] font-medium text-black transition-colors hover:bg-polydash-green-light"
      >
        View chart on DexScreener <ArrowUpRight className="h-3.5 w-3.5" />
      </a>
    </div>
  );
}
