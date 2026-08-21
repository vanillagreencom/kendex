import { useState } from "react";
import type { Finding } from "@/bindings";
import { FileLink } from "@/components/file-link";
import { InlineMarkdown } from "@/components/inline-markdown";
import { StatusDot } from "@/components/status-dot";
import { morePlacesLabel } from "@/lib/copy";
import { SEVERITY_DOT_TONE, SEVERITY_LABELS, sentence } from "@/lib/labels";

/**
 * One finding, read top to bottom as: what it is, what to do, where.
 *
 * How bad it is rides on the dot — the same dot the rows above use — so the
 * claim starts at the same left edge every time, and the word itself is on
 * the dot for anyone who needs it in text. The engine writes its messages
 * with `code` in them, so they render as the author wrote them rather than
 * printing their own backticks.
 *
 * Every place the rule fired is a file you can open. One is shown; the rest
 * are a click away in the same row, because a rule that fired in twenty
 * files would otherwise print a paragraph of paths nobody reads.
 */
export function FindingLine({
  finding,
  locations = [finding.location],
  settledBy,
}: {
  finding: Finding;
  locations?: string[];
  /** Present where somebody has already ruled on this finding: their line
   *  replaces the fix, because there is nothing here for the reader to do
   *  and the sentence that matters is whose call it was. */
  settledBy?: string;
}) {
  const [expanded, setExpanded] = useState(false);
  const shown = expanded ? locations : locations.slice(0, 1);
  const hidden = locations.length - shown.length;
  return (
    <div className="flex items-start gap-2.5">
      <StatusDot
        tone={SEVERITY_DOT_TONE[finding.severity]}
        className="mt-[7px]"
        title={SEVERITY_LABELS[finding.severity]}
      />
      <div className="flex min-w-0 flex-1 flex-col gap-2">
        <p className="text-sm break-words">
          <InlineMarkdown source={sentence(finding.message)} />
        </p>
        {/* The fix and the places sit on the claim's own left edge, not
            stepped in from it: an indent would read as a sub-list of the
            sentence rather than the rest of the same thought. */}
        {settledBy ? (
          <p className="pt-0.5 text-[13px] break-words text-foreground/70">
            {settledBy}
          </p>
        ) : (
          <p className="pt-0.5 text-[13px] break-words text-foreground/70">
            <span className="font-medium text-foreground">Fix: </span>
            {finding.remediation}
          </p>
        )}
        <div className="flex flex-wrap items-center gap-1.5">
          {shown.map((location) => (
            <FileLink key={location} location={location} />
          ))}
          {hidden > 0 ? (
            <button
              type="button"
              onClick={() => setExpanded(true)}
              className="text-xs text-muted-foreground underline underline-offset-2 hover:text-foreground"
            >
              {morePlacesLabel(hidden)}
            </button>
          ) : null}
        </div>
      </div>
    </div>
  );
}
