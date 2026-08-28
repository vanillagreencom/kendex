import type { Finding } from "@/bindings";
import type { Place } from "@/components/file-link";
import { FoundAt } from "@/components/found-at";
import { InlineMarkdown } from "@/components/inline-markdown";
import { StatusDot } from "@/components/status-dot";
import { SEVERITY_DOT_TONE, SEVERITY_LABELS, sentence } from "@/lib/labels";

/**
 * One finding, read top to bottom as: what it is, where. No fix line: the
 * score is advisory, and the finding says what was matched, not what to do.
 *
 * How bad it is rides on the dot — the same dot the rows above use — so the
 * claim starts at the same left edge every time, and the word itself leads
 * the message in visible text, so colour is never the only carrier for
 * anyone: sighted, keyboard, or screen reader alike. The engine writes its
 * messages with `code` in them, so they render as the author wrote them
 * rather than printing their own backticks.
 *
 * Every place the rule fired is a file you can open. One is shown; the rest
 * are a click away in the same row, because a rule that fired in twenty
 * files would otherwise print a paragraph of paths nobody reads.
 */
export function FindingLine({
  finding,
  places = [{ file: finding.location, line: finding.line }],
}: {
  finding: Finding;
  places?: Place[];
}) {
  return (
    <div className="flex items-start gap-2.5">
      <StatusDot
        tone={SEVERITY_DOT_TONE[finding.severity]}
        className="mt-[7px]"
        title={SEVERITY_LABELS[finding.severity]}
      />
      <div className="flex min-w-0 flex-1 flex-col gap-2">
        <p className="text-sm break-words">
          <span className="font-medium">
            {SEVERITY_LABELS[finding.severity]}:{" "}
          </span>
          <InlineMarkdown source={sentence(finding.message)} />
        </p>
        {/* The places sit on the claim's own left edge, not stepped in
            from it: an indent would read as a sub-list of the sentence
            rather than the rest of the same thought. */}
        <div className="flex flex-wrap items-center gap-1.5">
          <FoundAt places={places} />
        </div>
      </div>
    </div>
  );
}
