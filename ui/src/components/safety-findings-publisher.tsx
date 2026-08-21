import { ChevronDown, ChevronRight } from "lucide-react";
import { useState } from "react";
import type { ItemSafety } from "@/bindings";
import { FileLink } from "@/components/file-link";
import { InlineMarkdown } from "@/components/inline-markdown";
import { StatusDot } from "@/components/status-dot";
import {
  publisherSettledExplainer,
  publisherSettledLabel,
  publisherSettledNote,
} from "@/lib/copy-safety";
import { SEVERITY_DOT_TONE, SEVERITY_LABELS, sentence } from "@/lib/labels";
import { relativeTime } from "@/lib/relative-time";
import { authorOccurrences } from "@/lib/reviewable";

/**
 * What the publisher of an item already ruled on, on the machine that
 * installed it.
 *
 * Honouring somebody else's judgement is only defensible if the person it
 * is being honoured on behalf of can read it: every finding here is one the
 * gate stopped counting because a catalog's committed review said it was
 * not a problem, and every line names who said so, when, and why. It is
 * closed by default because nothing here needs doing — and it is one click
 * from open because "nothing to do" is not the same as "nothing happened".
 */
export function PublisherSettled({ rows }: { rows: ItemSafety[] }) {
  const [open, setOpen] = useState(false);
  const occurrences = authorOccurrences(rows);
  if (occurrences.length === 0) return null;
  return (
    <div className="flex flex-col gap-2">
      <button
        type="button"
        onClick={() => setOpen((o) => !o)}
        className="flex cursor-pointer items-center gap-1.5 self-start text-[13px] text-muted-foreground hover:text-foreground"
      >
        {open ? (
          <ChevronDown className="size-3.5" />
        ) : (
          <ChevronRight className="size-3.5" />
        )}
        {publisherSettledLabel(occurrences.length)}
      </button>
      {open ? (
        <div className="flex flex-col gap-3 pl-5">
          <p className="text-xs text-foreground/70">
            {publisherSettledExplainer}
          </p>
          {occurrences.map(({ row, finding, decision }) => {
            if (decision.state.state !== "author-dismissed") return null;
            const when = Date.parse(decision.state.dismissedAt);
            return (
              <div
                key={`${row.kind}:${row.name}:${row.harness}:${decision.fingerprint}`}
                className="flex items-start gap-2.5"
              >
                <StatusDot
                  tone={SEVERITY_DOT_TONE[finding.severity]}
                  className="mt-[7px]"
                  title={SEVERITY_LABELS[finding.severity]}
                />
                <div className="flex min-w-0 flex-1 flex-col gap-1.5">
                  <p className="text-sm break-words">
                    <InlineMarkdown source={sentence(finding.message)} />
                  </p>
                  <p className="text-[13px] break-words text-foreground/70">
                    {publisherSettledNote(
                      decision.state.publisher,
                      decision.state.reason,
                      Number.isNaN(when)
                        ? null
                        : relativeTime(when, Date.now()),
                    )}
                  </p>
                  <div className="flex flex-wrap items-center gap-1.5">
                    <span className="font-mono text-xs text-muted-foreground">
                      {finding.rule}
                    </span>
                    <FileLink location={finding.location} />
                  </div>
                </div>
              </div>
            );
          })}
        </div>
      ) : null}
    </div>
  );
}
