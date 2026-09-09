import type { HarnessId } from "@/bindings";
import { HarnessIcon } from "@/components/harness-icon";
import { Badge } from "@/components/ui/badge";
import {
  Tooltip,
  TooltipContent,
  TooltipTrigger,
} from "@/components/ui/tooltip";
import { harnessName } from "@/lib/labels";
import { cn } from "@/lib/utils";

// Written out per tool rather than composed from the id: Tailwind only
// emits classes it can see as whole strings in the source.
// A tinted fill rather than an outline: a row with five outlined chips reads
// as five buttons, where five washes of colour read as five labels.
const HARNESS_CHIP: Record<HarnessId, string> = {
  claude: "bg-harness-claude/12 text-harness-claude",
  codex: "bg-harness-codex/12 text-harness-codex",
  opencode: "bg-harness-opencode/12 text-harness-opencode",
  cursor: "bg-harness-cursor/12 text-harness-cursor",
  pi: "bg-harness-pi/12 text-harness-pi",
  gemini: "bg-harness-gemini/12 text-harness-gemini",
  copilot: "bg-harness-copilot/12 text-harness-copilot",
  antigravity: "bg-harness-antigravity/12 text-harness-antigravity",
};

/**
 * The tool a thing is installed for, as a chip you can pick out of a row
 * without reading it.
 *
 * `compact` drops the name and keeps the mark. In a table every row carries
 * the same five or six tools, so the names are a column of repeated words
 * pushing the columns that differ off the screen — the logo and its hue
 * already tell them apart, and the name arrives on hover. Where a tool is
 * stated once rather than listed — a package's own details — the name stays
 * written out, since there is nothing there to scan past.
 */
export function HarnessBadge({
  harness,
  compact,
  className,
  onOpen,
}: {
  harness: HarnessId;
  compact?: boolean;
  className?: string;
  /** Open this harness. Given one, the chip is the way in — a chip that
   *  names a thing opens that thing. Without one it is a label, and stays
   *  out of the tab order. */
  onOpen?: () => void;
}) {
  const label = harnessName(harness);
  // A chip stays a quiet fill whether or not it opens something: what makes
  // it actionable is that it is a button, not a border, which this app
  // keeps for buttons and inputs.
  const chipClass = cn(
    "border-transparent",
    compact && "px-1.5",
    onOpen && "cursor-pointer",
    HARNESS_CHIP[harness],
    className,
  );
  const face = compact ? (
    <HarnessIcon harness={harness} className="size-3.5" />
  ) : (
    <>
      <HarnessIcon harness={harness} className="size-3" />
      {label}
    </>
  );
  const badge = onOpen ? (
    <Badge
      className={chipClass}
      render={
        <button type="button" aria-label={label} onClick={onOpen}>
          {face}
        </button>
      }
    />
  ) : (
    <Badge aria-label={compact ? label : undefined} className={chipClass}>
      {face}
    </Badge>
  );
  // Compact drops the name, so the name arrives on hover and on focus.
  // Written out, the chip already says it.
  if (!compact) return badge;
  return (
    <Tooltip>
      <TooltipTrigger render={badge} />
      <TooltipContent>{label}</TooltipContent>
    </Tooltip>
  );
}
