import { Loader2 } from "lucide-react";
import { useEffect } from "react";
import type { CommandLink } from "@/bindings";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { useMayAsk } from "@/lib/asks-first";
import {
  CANCELLED_LINE,
  CLOSE_LABEL,
  COMMAND_LINK_DONE_TITLE,
  COMMAND_LINK_NOT_INSTALLED_TITLE,
  COMMAND_LINK_TITLE,
  DECLINE_LABEL,
  DONE_LABEL,
  failedLine,
  INSTALL_LABEL,
  INSTALLING_LABEL,
  installedLine,
  LATER_IN_SETTINGS,
  standing,
  TRY_AGAIN_LABEL,
  WAITING_FOR_PASSWORD,
} from "@/lib/copy-command-link";
import { type Stage, useCommandLinkStore } from "@/stores/command-link";

/**
 * The macOS app's first-launch question: install the kendex command it
 * carries, by linking it into `/usr/local/bin`.
 *
 * Put once. Whether to put it is the backend's answer (`ask`), held by the
 * store as `question` until it is answered, and any way out of the dialog
 * records it as answered, so the Settings row is the only way back to it. It waits its turn behind every other question
 * (`lib/asks-first.ts`).
 */
export function CommandLinkDialog() {
  const offered = useCommandLinkStore((s) => s.question);
  const stage = useCommandLinkStore((s) => s.stage);
  const load = useCommandLinkStore((s) => s.load);
  const install = useCommandLinkStore((s) => s.install);
  const answer = useCommandLinkStore((s) => s.answer);
  const mayAsk = useMayAsk("commandLink");

  useEffect(() => {
    void load();
  }, [load]);

  if (offered === null || !mayAsk) return null;
  const working = stage.at === "working";

  return (
    <Dialog
      open
      onOpenChange={(next) => {
        // The administrator prompt is up; closing this would not close it.
        if (!next && !working) void answer();
      }}
    >
      {/* The paths are long unbroken words; overflow-wrap is inherited, so
          one class here wraps every line below. */}
      <DialogContent className="break-words" showCloseButton={!working}>
        <Body
          stage={stage}
          offered={offered}
          onInstall={() => void install()}
          onClose={() => void answer()}
        />
      </DialogContent>
    </Dialog>
  );
}

function Body({
  stage,
  offered,
  onInstall,
  onClose,
}: {
  stage: Stage;
  offered: Extract<CommandLink, { kind: "offered" }>;
  onInstall: () => void;
  onClose: () => void;
}) {
  switch (stage.at) {
    case "idle":
    case "working":
    case "cancelled":
    case "failed": {
      const working = stage.at === "working";
      return (
        <>
          <DialogHeader>
            <DialogTitle>{COMMAND_LINK_TITLE}</DialogTitle>
            <DialogDescription>{standing(offered)}</DialogDescription>
          </DialogHeader>
          <Note stage={stage} />
          <DialogFooter>
            <Button variant="outline" disabled={working} onClick={onClose}>
              {DECLINE_LABEL}
            </Button>
            <Button disabled={working} onClick={onInstall}>
              {working ? <Loader2 className="animate-spin" /> : null}
              {working
                ? INSTALLING_LABEL
                : stage.at === "idle"
                  ? INSTALL_LABEL
                  : TRY_AGAIN_LABEL}
            </Button>
          </DialogFooter>
        </>
      );
    }
    case "done":
      return (
        <>
          <DialogHeader>
            <DialogTitle>{COMMAND_LINK_DONE_TITLE}</DialogTitle>
            <DialogDescription>{installedLine(offered.link)}</DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button onClick={onClose}>{DONE_LABEL}</Button>
          </DialogFooter>
        </>
      );
    case "refused":
      return (
        <>
          <DialogHeader>
            <DialogTitle>{COMMAND_LINK_NOT_INSTALLED_TITLE}</DialogTitle>
            <DialogDescription role="alert">
              {standing(stage.command)}
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button onClick={onClose}>{CLOSE_LABEL}</Button>
          </DialogFooter>
        </>
      );
    default: {
      const unreachable: never = stage;
      return unreachable;
    }
  }
}

/** The line under the offer: where the attempt stands, or where to find it
 *  later. */
function Note({
  stage,
}: {
  stage: Extract<Stage, { at: "idle" | "working" | "cancelled" | "failed" }>;
}) {
  switch (stage.at) {
    case "idle":
      return (
        <p className="text-[13px] text-muted-foreground">{LATER_IN_SETTINGS}</p>
      );
    case "working":
      return (
        <p className="text-[13px] text-muted-foreground" aria-live="polite">
          {WAITING_FOR_PASSWORD}
        </p>
      );
    case "cancelled":
      return (
        <p className="text-[13px] text-warning" role="alert">
          {CANCELLED_LINE}
        </p>
      );
    case "failed":
      return (
        <p className="text-[13px] text-critical" role="alert">
          {failedLine(stage.message)}
        </p>
      );
    default: {
      const unreachable: never = stage;
      return unreachable;
    }
  }
}
