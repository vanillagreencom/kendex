import { Loader2, X } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  APP_UPDATE_COMMAND_UNKNOWN_NOTE,
  APP_UPDATE_DISMISS_LABEL,
  APP_UPDATE_INSTALL_LABEL,
  APP_UPDATE_INSTALLING_LABEL,
  APP_UPDATE_MANAGED_NOTE,
  APP_UPDATE_NOTES_LABEL,
  APP_UPDATE_TITLE,
  APP_UPDATE_UNKNOWN_NOTE,
  appUpdateCommandDownloadNote,
  appUpdateCommandManagedNote,
  appUpdateCommandPrivilegeNote,
  appUpdateVersionsLabel,
} from "@/lib/copy";
import { useNoticeStore } from "@/stores/notice";

/**
 * The app's own out-of-date notice: one card at the foot of the sidebar,
 * shown once a check has found this build behind a release the person has
 * not hidden. It never takes the window, never interrupts what is on
 * screen, and offers only the action the running install allows — a
 * replacement kendex can do, a command kendex must not run, or neither.
 */
export function SidebarNotice() {
  const notice = useNoticeStore((s) => s.notice);
  const channel = useNoticeStore((s) => s.channel);
  const commandChannel = useNoticeStore((s) => s.commandChannel);
  const installing = useNoticeStore((s) => s.installing);
  const error = useNoticeStore((s) => s.error);
  const note = useNoticeStore((s) => s.note);
  const install = useNoticeStore((s) => s.install);
  const openNotes = useNoticeStore((s) => s.openNotes);
  const dismiss = useNoticeStore((s) => s.dismiss);

  if (notice === null) return null;

  return (
    // The one animation in the chrome, and it runs once: the card mounts
    // when the check lands and stays put until it is hidden.
    <div className="mx-2 mb-2 animate-in rounded-lg border bg-card p-2.5 text-card-foreground duration-300 fade-in slide-in-from-bottom-2">
      <div className="flex items-center gap-1.5">
        <span className="min-w-0 flex-1 truncate text-sm font-medium">
          {APP_UPDATE_TITLE}
        </span>
        <span className="shrink-0 rounded bg-foreground/[0.09] px-1.5 py-0.5 font-mono text-[11px] tabular-nums">
          {notice.latest}
        </span>
        <Button
          variant="quiet"
          size="icon-xs"
          className="-mr-1 shrink-0"
          aria-label={APP_UPDATE_DISMISS_LABEL}
          title={APP_UPDATE_DISMISS_LABEL}
          // The card is what would report a failed replacement, so it
          // cannot be taken away while one is running.
          disabled={installing}
          onClick={() => void dismiss()}
        >
          <X className="size-3.5" />
        </Button>
      </div>

      <p className="mt-1 text-xs text-muted-foreground">
        {appUpdateVersionsLabel(notice.latest, notice.current)}
      </p>

      {channel.kind === "direct" ? (
        <>
          {/* Once the release is installed there is nothing left to press:
              the next launch is what completes it, and offering the action
              again would download and write a release already on disk. */}
          {note !== null ? null : (
            <Button
              size="sm"
              className="mt-2.5 w-full"
              disabled={installing}
              onClick={() => void install()}
            >
              {installing ? (
                <>
                  <Loader2 className="animate-spin" />
                  {APP_UPDATE_INSTALLING_LABEL}
                </>
              ) : (
                APP_UPDATE_INSTALL_LABEL
              )}
            </Button>
          )}
          {/* The app is kendex's to replace and the command beside it is
              not, so Update now moves one and leaves the other. Said
              before the button is pressed, because an install that
              restarts takes the card with it; an install that answers
              instead leaves the card up and this is read again for it. */}
          {commandChannel === null ? null : commandChannel.kind ===
            "unknown" ? (
            // Nothing named the installer, so there is no name to print
            // and no command to run: the card says the app moves alone and
            // stops, rather than leaving a gap where a name would go.
            <p className="mt-2 text-xs text-muted-foreground">
              {APP_UPDATE_COMMAND_UNKNOWN_NOTE}
            </p>
          ) : (
            <>
              <p className="mt-2 text-xs text-muted-foreground">
                {commandChannel.kind === "managed"
                  ? appUpdateCommandManagedNote(commandChannel.manager)
                  : commandChannel.kind === "needsDownload"
                    ? appUpdateCommandDownloadNote(commandChannel.path)
                    : appUpdateCommandPrivilegeNote(commandChannel.path)}
              </p>
              {/* A page to open where there is no installer to run, and a
                  command to copy where there is. Both are text on the card
                  either way: the app runs neither. */}
              <pre className="mt-1 overflow-x-auto whitespace-pre-wrap break-words rounded bg-foreground/[0.05] px-2 py-1.5 font-mono text-[11px] leading-5">
                {commandChannel.kind === "needsDownload"
                  ? commandChannel.page
                  : commandChannel.command}
              </pre>
            </>
          )}
        </>
      ) : channel.kind === "managed" ? (
        <>
          <p className="mt-2.5 text-xs text-muted-foreground">
            {APP_UPDATE_MANAGED_NOTE}
          </p>
          {/* The command a package manager takes, to read and to copy. It
              is text on the card, never something the app runs: these
              files are not kendex's to replace. It wraps rather than
              scrolls — a channel with no helper on the machine names what
              to do in words, and a sentence behind a scrollbar in a
              224px column is a sentence nobody reads. */}
          <pre className="mt-1 overflow-x-auto whitespace-pre-wrap break-words rounded bg-foreground/[0.05] px-2 py-1.5 font-mono text-[11px] leading-5">
            {channel.command}
          </pre>
        </>
      ) : (
        <p className="mt-2.5 text-xs text-muted-foreground">
          {APP_UPDATE_UNKNOWN_NOTE}
        </p>
      )}

      {/* Whatever the last action refused, said where that action is. The
          app is untouched and still usable either way. */}
      {error === null ? null : (
        <p className="mt-2 break-words text-xs text-critical">{error}</p>
      )}

      {/* What an install that went through still owed the person. The
          release is on disk and the next launch runs it, so this is a
          sentence about the command beside the app and not a failure.

          `role="status"` because it arrives after the press, in the same
          render that takes away the button the person was on: unannounced,
          the only sentence saying what happened to their command is one
          nothing reads out. The role carries a polite `aria-live` and
          `aria-atomic` of its own, so neither is spelled again here. */}
      {note === null ? null : (
        <p
          role="status"
          className="mt-2 break-words text-xs text-muted-foreground"
        >
          {note}
        </p>
      )}

      <button
        type="button"
        className="mt-2.5 text-xs text-muted-foreground underline-offset-2 hover:text-foreground hover:underline"
        onClick={() => void openNotes()}
      >
        {APP_UPDATE_NOTES_LABEL}
      </button>
    </div>
  );
}
