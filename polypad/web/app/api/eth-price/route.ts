import { NextResponse } from 'next/server';

export const dynamic = 'force-dynamic';

let cache: { price: number; at: number } | null = null;

export async function GET() {
  try {
    if (cache && Date.now() - cache.at < 60_000) return NextResponse.json({ price: cache.price });
    const res = await fetch('https://api.coinbase.com/v2/prices/ETH-USD/spot', { cache: 'no-store' });
    const json = await res.json();
    const price = Number(json?.data?.amount);
    if (!Number.isFinite(price) || price <= 0) throw new Error('bad price');
    cache = { price, at: Date.now() };
    return NextResponse.json({ price });
  } catch (e) {
    console.error('eth-price error', e);
    return NextResponse.json({ price: cache?.price ?? 0 });
  }
}
