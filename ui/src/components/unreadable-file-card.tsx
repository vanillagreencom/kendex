import { toast } from "sonner";
import { commands, type ScanWarning } from "@/bindings";
import { PlaceCard } from "@/components/place-card";
import { Button } from "@/components/ui/button";
import { COPY_PATH_LABEL, PATH_COPIED_TOAST } from "@/lib/copy";
import {
  RESCAN_LABEL,
  SHOW_IN_FILE_BROWSER_LABEL,
  unreadableFileRemedy,
  unreadableFileTitle,
} from "@/lib/copy-scan";
import { harnessName } from "@/lib/labels";
import { rescanEverything } from "@/lib/rescan";

/** One file the scan could not read: whose it is, where it is, what is
 *  wrong and what to do. The remedy is the reader's — another tool's
 *  file is not kendex's to rewrite — so the buttons get them to it: the
 *  path to paste, the folder to open, and the rescan once it is fixed. */
export function UnreadableFileCard({ warning }: { warning: ScanWarning }) {
  return (
    <PlaceCard
      tone="warning"
      headline={unreadableFileTitle(warning)}
      name={harnessName(warning.harness)}
      path={warning.path}
    >
      <p className="text-sm">{unreadableFileRemedy(warning)}</p>
      <div className="flex flex-wrap gap-2">
        <Button
          size="sm"
          variant="outline"
          onClick={() => void rescanEverything({ announce: true })}
        >
          {RESCAN_LABEL}
        </Button>
        <Button
          size="sm"
          variant="outline"
          onClick={() => {
            void navigator.clipboard.writeText(warning.path);
            toast.success(PATH_COPIED_TOAST);
          }}
        >
          {COPY_PATH_LABEL}
        </Button>
        <Button
          size="sm"
          variant="outline"
          onClick={() => void commands.revealPath(warning.path)}
        >
          {SHOW_IN_FILE_BROWSER_LABEL}
        </Button>
      </div>
    </PlaceCard>
  );
}
