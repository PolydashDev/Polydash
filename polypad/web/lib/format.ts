import { formatEther, formatUnits } from 'viem';

export function formatEth(wei: bigint | undefined | null, decimals = 4): string {
  if (wei == null) return '0';
  const val = Number(formatEther(wei));
  if (val === 0) return '0';
  if (val < 0.0001) return '<0.0001';
  return val.toLocaleString('en-US', { minimumFractionDigits: 0, maximumFractionDigits: decimals });
}

export function formatTokens(wei: bigint | undefined | null, decimals = 18, display = 2): string {
  if (wei == null) return '0';
  const val = Number(formatUnits(wei, decimals));
  if (val === 0) return '0';
  if (val >= 1_000_000_000) return `${(val / 1_000_000_000).toFixed(display)}B`;
  if (val >= 1_000_000) return `${(val / 1_000_000).toFixed(display)}M`;
  if (val >= 1_000) return `${(val / 1_000).toFixed(display)}K`;
  return val.toLocaleString('en-US', { maximumFractionDigits: display });
}

export function formatUsd(val: number | undefined | null): string {
  if (val == null) return '$0';
  if (val >= 1_000_000) return `$${(val / 1_000_000).toFixed(2)}M`;
  if (val >= 1_000) return `$${(val / 1_000).toFixed(2)}K`;
  return `$${val.toFixed(2)}`;
}

export function formatCompact(v: number): string {
  if (!Number.isFinite(v)) return '0';
  if (v >= 1e9) return `${(v / 1e9).toFixed(2)}B`;
  if (v >= 1e6) return `${(v / 1e6).toFixed(2)}M`;
  if (v >= 1e3) return `${(v / 1e3).toFixed(2)}K`;
  if (v >= 1) return v.toFixed(2);
  if (v === 0) return '0';
  return v.toPrecision(3);
}

export function shortenAddress(addr: string | undefined | null): string {
  if (!addr) return '';
  return `${addr.slice(0, 6)}...${addr.slice(-4)}`;
}

export function bpsToPercent(bps: bigint | number | undefined | null): string {
  if (bps == null) return '0%';
  return `${(Number(bps) / 100).toFixed(2)}%`;
}
