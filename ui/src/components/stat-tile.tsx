import type { ReactNode } from "react";
import { cn } from "@/lib/utils";

/** A clickable number-over-label tile, for at-a-glance stat strips. */
export function StatTile({
  label,
  value,
  detail,
  onClick,
}: {
  label: string;
  /** A count, or null when the read behind it has not answered — a tile
   *  must not show a definite zero off a read that failed, and the dash
   *  that stands in is this component's to draw. */
  value: number | null;
  detail?: ReactNode;
  onClick?: () => void;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      disabled={!onClick}
      className={cn(
        "rounded-lg border px-4 py-3 text-left transition-colors",
        onClick && "cursor-pointer hover:bg-accent",
      )}
    >
      <p className="text-2xl font-semibold tracking-tight">{value ?? "—"}</p>
      <p className="text-xs font-medium tracking-widest text-muted-foreground uppercase">
        {label}
      </p>
      {detail ? (
        <div className="mt-1 truncate text-xs text-muted-foreground">
          {detail}
        </div>
      ) : null}
    </button>
  );
}
