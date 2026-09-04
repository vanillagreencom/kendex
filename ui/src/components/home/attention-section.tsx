import { ChevronRight } from "lucide-react";
import { StatusDot } from "@/components/status-dot";

export interface AttentionRow {
  key: string;
  tone: "critical" | "warning" | "info" | "muted";
  title: string;
  /** Only where it says something the title does not. */
  detail?: string;
  action?: { label: string; onClick: () => void };
}

/**
 * The lead of Home: what needs a person's judgment, worst first. Home drops
 * the whole section when there is nothing in it.
 *
 * One list, not a stack of cards. Rows that all land in the same place, each
 * with the same blue button, read as several different places to go; the row
 * itself is the way in, and where it lands is said once, quietly, beside the
 * chevron.
 */
export function AttentionSection({ rows }: { rows: AttentionRow[] }) {
  return (
    <div className="divide-y overflow-hidden rounded-xl border bg-card">
      {rows.map((row) => (
        <AttentionLine key={row.key} row={row} />
      ))}
    </div>
  );
}

function AttentionLine({ row }: { row: AttentionRow }) {
  const body = (
    <>
      <StatusDot tone={row.tone} className="mt-1.5 self-start" />
      <span className="flex min-w-0 flex-1 flex-col">
        <span className="text-sm font-medium">{row.title}</span>
        {row.detail ? (
          <span className="text-[13px] text-muted-foreground">
            {row.detail}
          </span>
        ) : null}
      </span>
      {row.action ? (
        // Centred against the whole row, not its first line: a destination
        // belongs to the row, and hung off the top it reads as part of the
        // headline instead.
        <span className="flex shrink-0 items-center gap-1 text-[13px] text-muted-foreground">
          {row.action.label}
          <ChevronRight className="size-4" />
        </span>
      ) : null}
    </>
  );
  // A row with nowhere to go is a statement, not a control — it must not
  // light up under the pointer as if a click would do something.
  if (!row.action) {
    return <div className="flex items-center gap-3 px-4 py-3.5">{body}</div>;
  }
  return (
    <button
      type="button"
      onClick={row.action.onClick}
      className="flex w-full items-center gap-3 px-4 py-3.5 text-left transition-colors hover:bg-muted/40"
    >
      {body}
    </button>
  );
}
