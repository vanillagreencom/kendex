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
}: {
  harness: HarnessId;
  compact?: boolean;
  className?: string;
}) {
  if (compact) {
    return (
      <Tooltip>
        <TooltipTrigger
          render={
            <Badge
              aria-label={harnessName(harness)}
              className={cn(
                "border-transparent px-1.5",
                HARNESS_CHIP[harness],
                className,
              )}
            >
              <HarnessIcon harness={harness} className="size-3.5" />
            </Badge>
          }
        />
        <TooltipContent>{harnessName(harness)}</TooltipContent>
      </Tooltip>
    );
  }
  return (
    <Badge
      className={cn("border-transparent", HARNESS_CHIP[harness], className)}
    >
      <HarnessIcon harness={harness} className="size-3" />
      {harnessName(harness)}
    </Badge>
  );
}
