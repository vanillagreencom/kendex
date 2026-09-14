import { ChevronRight, X } from "lucide-react";
import {
  type AttentionCard,
  type AttentionClass,
  CLASS_TONES,
} from "@/components/home/attention-rows";
import { StatusDot } from "@/components/status-dot";
import { Button } from "@/components/ui/button";
import { DISMISS_NOTICE_LABEL } from "@/lib/copy";
import { type ReadKey, useReadNotices } from "@/stores/read-notices";

export interface AttentionRow {
  key: string;
  class: AttentionClass;
  title: string;
  /** Only where it says something the title does not. */
  detail?: string;
  action?: { label: string; onClick: () => void };
  /** The Problems card this item keeps, where it has one. */
  card?: AttentionCard;
  /** Where a Notice or Update row records that it was read. A Problem or
   *  Decision has none, so it carries no dismiss control. */
  readKey?: ReadKey;
}

/**
 * The lead of Home: every item that asks something of the person, in class
 * order. Home drops the whole section when there is nothing in it.
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
  const markRead = useReadNotices((s) => s.markRead);
  const body = (
    <>
      <StatusDot tone={CLASS_TONES[row.class]} className="mt-1.5 self-start" />
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
  const line = row.action ? (
    <button
      type="button"
      onClick={row.action.onClick}
      className="flex w-full min-w-0 flex-1 items-center gap-3 px-4 py-3.5 text-left transition-colors hover:bg-muted/40"
    >
      {body}
    </button>
  ) : (
    <div className="flex min-w-0 flex-1 items-center gap-3 px-4 py-3.5">
      {body}
    </div>
  );
  const { readKey } = row;
  if (!readKey) return line;
  // Beside the row, never inside it: a button nested in the row's own
  // button is invalid, and the keyboard could not reach it on its own.
  return (
    <div className="flex items-center">
      {line}
      <Button
        variant="quiet"
        size="icon-xs"
        className="mr-3 shrink-0"
        aria-label={DISMISS_NOTICE_LABEL}
        title={DISMISS_NOTICE_LABEL}
        onClick={() => markRead(readKey)}
      >
        <X className="size-3.5" />
      </Button>
    </div>
  );
}
