'use client';

import { ResponsiveContainer, AreaChart, Area, XAxis, YAxis, Tooltip, CartesianGrid } from 'recharts';
import { formatCompact as compactNum } from '@/lib/format';

export interface McapPoint { t: number; mcap: number }

const axis = 'rgba(255,255,255,0.35)';


function timeLabel(t: number, span: number) {
  const d = new Date(t);
  if (span <= 36 * 3600_000) return d.toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit', hour12: false });
  return d.toLocaleDateString('en-US', { month: 'short', day: 'numeric' });
}

export default function LineChartInner({ data, unit, up }: { data: McapPoint[]; unit: 'USD' | 'ETH'; up: boolean }) {
  const fmt = (v: number) => (unit === 'USD' ? `$${compactNum(v)}` : `${compactNum(v)} Ξ`);
  const color = up ? '#00E676' : '#FF5252';
  const span = data.length > 1 ? data[data.length - 1].t - data[0].t : 0;
  const max = Math.max(...data.map((d) => d.mcap));
  const min = Math.min(...data.map((d) => d.mcap));
  // Keep at least ±4% headroom so tiny moves on a near-flat curve aren't blown up into cliffs.
  const pad = Math.max((max - min) * 0.15, max * 0.04);
  return (
    <div className="h-[260px] sm:h-[340px] w-full">
      <ResponsiveContainer width="100%" height="100%">
        <AreaChart data={data} margin={{ top: 8, right: 0, left: 0, bottom: 0 }}>
          <defs>
            <linearGradient id="mcapFill" x1="0" y1="0" x2="0" y2="1">
              <stop offset="0%" stopColor={color} stopOpacity={0.28} />
              <stop offset="100%" stopColor={color} stopOpacity={0} />
            </linearGradient>
          </defs>
          <CartesianGrid stroke="rgba(255,255,255,0.05)" vertical={false} />
          <XAxis
            dataKey="t"
            type="number"
            scale="time"
            domain={['dataMin', 'dataMax']}
            tickLine={false}
            axisLine={false}
            minTickGap={40}
            tick={{ fontSize: 10, fill: axis }}
            tickFormatter={(v: number) => timeLabel(v, span)}
          />
          <YAxis
            orientation="right"
            tickLine={false}
            axisLine={false}
            width={58}
            domain={[Math.max(0, min - pad), max + pad]}
            tick={{ fontSize: 10, fill: axis }}
            tickFormatter={fmt}
          />
          <Tooltip
            cursor={{ stroke: 'rgba(255,255,255,0.2)', strokeDasharray: '3 3' }}
            contentStyle={{ backgroundColor: '#111', border: '1px solid rgba(255,255,255,0.1)', borderRadius: 10, fontSize: 11, color: '#fff' }}
            labelFormatter={(v: any) => new Date(Number(v)).toLocaleString('en-US', { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit', hour12: false })}
            formatter={(value: any) => [fmt(Number(value)), 'Market cap']}
          />
          <Area type="stepAfter" dataKey="mcap" stroke={color} strokeWidth={1.75} fill="url(#mcapFill)" isAnimationActive={false} activeDot={{ r: 3.5, fill: color, stroke: '#0A0A0A' }} />
        </AreaChart>
      </ResponsiveContainer>
    </div>
  );
}
