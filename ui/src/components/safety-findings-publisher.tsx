import { ChevronDown, ChevronRight } from "lucide-react";
import { useState } from "react";
import { FileLink } from "@/components/file-link";
import { InlineMarkdown } from "@/components/inline-markdown";
import { StatusDot } from "@/components/status-dot";
import {
  publisherSettledExplainer,
  publisherSettledLabel,
  publisherSettledNote,
} from "@/lib/copy-safety";
import {
  harnessName,
  SEVERITY_DOT_TONE,
  SEVERITY_LABELS,
  sentence,
} from "@/lib/labels";
import { relativeTime } from "@/lib/relative-time";
import type { PublisherGroup } from "@/lib/reviewable";

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
export function PublisherSettled({ groups }: { groups: PublisherGroup[] }) {
  const [open, setOpen] = useState(false);
  if (groups.length === 0) return null;
  return (
    <div className="flex flex-col gap-2">
      <button
        type="button"
        onClick={() => setOpen((o) => !o)}
        aria-expanded={open}
        className="flex cursor-pointer items-center gap-1.5 self-start text-[13px] text-muted-foreground hover:text-foreground"
      >
        {open ? (
          <ChevronDown className="size-3.5" />
        ) : (
          <ChevronRight className="size-3.5" />
        )}
        {publisherSettledLabel(groups.length)}
      </button>
      {open ? (
        <div className="flex flex-col gap-3 pl-5">
          <p className="text-xs text-foreground/70">
            {publisherSettledExplainer}
          </p>
          {groups.map((group) => {
            const when = Date.parse(group.dismissedAt);
            const tools = [
              ...new Set(group.items.map((item) => harnessName(item.harness))),
            ];
            return (
              <div
                key={`${group.items[0]?.kind}:${group.items[0]?.name}:${group.finding.rule}:${group.finding.location}`}
                className="flex items-start gap-2.5"
              >
                <StatusDot
                  tone={SEVERITY_DOT_TONE[group.finding.severity]}
                  className="mt-[7px]"
                  title={SEVERITY_LABELS[group.finding.severity]}
                />
                <div className="flex min-w-0 flex-1 flex-col gap-1.5">
                  <p className="text-sm break-words">
                    <InlineMarkdown source={sentence(group.finding.message)} />
                  </p>
                  <p className="text-[13px] break-words text-foreground/70">
                    {publisherSettledNote(
                      group.publisher,
                      group.reason,
                      Number.isNaN(when)
                        ? null
                        : relativeTime(when, Date.now()),
                    )}
                  </p>
                  <div className="flex flex-wrap items-center gap-1.5">
                    <span className="font-mono text-xs text-muted-foreground">
                      {group.finding.rule}
                    </span>
                    <FileLink location={group.finding.location} />
                    <span className="text-xs text-muted-foreground">
                      {group.items[0]?.name} · {tools.join(", ")}
                    </span>
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
