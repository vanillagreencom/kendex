import { Loader2 } from "lucide-react";
import { useEffect } from "react";
import type { CommandLink } from "@/bindings";
import { Section, SettingRow } from "@/components/section";
import { Button } from "@/components/ui/button";
import {
  CANCELLED_LINE,
  COMMAND_LINK_ROW_LABEL,
  COMMAND_LINK_SECTION,
  failedLine,
  INSTALL_LABEL,
  INSTALLING_LABEL,
  REPOINT_LABEL,
  standing,
  standingWord,
  TRY_AGAIN_LABEL,
  WAITING_FOR_PASSWORD,
} from "@/lib/copy-command-link";
import { type Stage, useCommandLinkStore } from "@/stores/command-link";

/**
 * The Settings way to the kendex command the macOS app carries: where it
 * stands, and the install the first-launch question offered, for as long
 * as it is on offer. Not drawn where the running app carries no command —
 * every build that is not the macOS app.
 */
export function CommandLinkSection() {
  const state = useCommandLinkStore((s) => s.state);
  const readError = useCommandLinkStore((s) => s.readError);
  const stage = useCommandLinkStore((s) => s.stage);
  const load = useCommandLinkStore((s) => s.load);
  const install = useCommandLinkStore((s) => s.install);

  useEffect(() => {
    // Whatever was installed since the page was last open — here, by
    // Homebrew, or by hand — is read again.
    void load();
  }, [load]);

  if (state === null) {
    if (readError === null) return null;
    return (
      <Section title={COMMAND_LINK_SECTION}>
        <SettingRow
          role="alert"
          label={COMMAND_LINK_ROW_LABEL}
          description={`kendex couldn't read whether its command is installed: ${readError}`}
        >
          <Button variant="outline" size="sm" onClick={() => void load()}>
            {TRY_AGAIN_LABEL}
          </Button>
        </SettingRow>
      </Section>
    );
  }
  const command = state.command;
  if (command.kind === "notCarried") return null;
  const working = stage.at === "working";

  return (
    <Section title={COMMAND_LINK_SECTION}>
      <SettingRow
        className="break-words"
        role={attempt(stage) === null ? undefined : "alert"}
        label={
          <span className="flex items-baseline gap-2">
            {COMMAND_LINK_ROW_LABEL}
            <span className="font-mono text-xs font-normal text-muted-foreground">
              {standingWord(command)}
            </span>
          </span>
        }
        description={
          <>
            {standing(command)}
            {attempt(stage) === null ? null : (
              <span className={attemptTone(stage)}> {attempt(stage)}</span>
            )}
          </>
        }
      >
        {command.kind === "offered" ? (
          <Button
            variant="outline"
            size="sm"
            disabled={working}
            onClick={() => void install()}
          >
            {working ? <Loader2 className="animate-spin" /> : null}
            {working ? INSTALLING_LABEL : installLabel(command)}
          </Button>
        ) : null}
      </SettingRow>
    </Section>
  );
}

function installLabel(command: Extract<CommandLink, { kind: "offered" }>) {
  return command.replaces === null ? INSTALL_LABEL : REPOINT_LABEL;
}

/** What the attempt in flight or just ended adds to the row. A refusal and
 *  a finished install add nothing: the row is read again, and what it now
 *  says is the answer. */
function attempt(stage: Stage): string | null {
  switch (stage.at) {
    case "idle":
    case "done":
    case "refused":
      return null;
    case "working":
      return WAITING_FOR_PASSWORD;
    case "cancelled":
      return CANCELLED_LINE;
    case "failed":
      return failedLine(stage.message);
    default: {
      const unreachable: never = stage;
      return unreachable;
    }
  }
}

function attemptTone(stage: Stage): string {
  switch (stage.at) {
    case "cancelled":
      return "text-warning";
    case "failed":
      return "text-critical";
    case "idle":
    case "working":
    case "done":
    case "refused":
      return "";
    default: {
      const unreachable: never = stage;
      return unreachable;
    }
  }
}
