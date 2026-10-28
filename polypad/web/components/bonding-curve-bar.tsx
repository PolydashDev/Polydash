'use client';

import { cn } from '@/lib/utils';

export function BondingCurveBar({
  progress,
  className,
  showLabel = true,
}: {
  progress: number;
  className?: string;
  showLabel?: boolean;
}) {
  const pct = Math.min(100, Math.max(0, progress ?? 0));
  const isNearGrad = pct >= 90;
  const isGraduated = pct >= 100;

  return (
    <div className={cn('space-y-1', className)}>
      {showLabel && (
        <div className="flex items-center justify-between text-xs">
          <span className="text-muted-foreground">Bonding Curve</span>
          <span className={cn(
            'font-mono font-semibold',
            isGraduated ? 'text-primary' : isNearGrad ? 'text-yellow-400' : 'text-foreground'
          )}>
            {pct.toFixed(0)}%
          </span>
        </div>
      )}
      <div className="h-2 rounded-full bg-secondary overflow-hidden">
        <div
          className={cn(
            'h-full rounded-full transition-all duration-500',
            isGraduated
              ? 'bg-primary'
              : isNearGrad
                ? 'bg-gradient-to-r from-yellow-400 to-primary'
                : 'bg-gradient-to-r from-accent to-primary'
          )}
          style={{ width: `${pct}%` }}
        />
      </div>
    </div>
  );
}
