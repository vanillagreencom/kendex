import { Pencil } from "lucide-react";
import { useState } from "react";
import type { HarnessId, ItemKind } from "@/bindings";
import { HarnessIcon } from "@/components/harness-icon";
import { HarnessFolderDialog } from "@/components/harnesses/harness-folder-dialog";
import { ShowEverythingButton } from "@/components/harnesses/show-everything-button";
import { KindCountBadges } from "@/components/kind-count-badges";
import { Button } from "@/components/ui/button";
import { HARNESS_FOLDER_HELP, NOT_INSTALLED_LABEL } from "@/lib/copy";
import { harnessName } from "@/lib/labels";
import { cn } from "@/lib/utils";
import { useNavStore } from "@/stores/nav";

/** One detected (or missing) harness, as a single compact row.
 *
 * Where the harness keeps its files is the row's second line, and changing it
 * is a pencil on that line — a page-long second list of the same seven
 * harnesses, one "Set folder" button each, said the same thing twice and buried
 * the fact that almost nobody needs it. */
export function HarnessRow({
  id,
  detectedRoot,
  version,
  counts,
  folder,
  onFolderChange,
}: {
  id: HarnessId;
  detectedRoot: string | null;
  version: string | null;
  counts: [ItemKind, number][];
  /** The folder this harness was pointed at by hand, when it was. */
  folder: string;
  onFolderChange: (root: string) => void;
}) {
  const goToLibrary = useNavStore((s) => s.goToLibrary);
  const [editing, setEditing] = useState(false);
  const name = harnessName(id);

  return (
    <div className="group flex items-start justify-between gap-6 py-3.5">
      <div className="flex min-w-0 flex-col gap-1">
        <span className="flex items-center gap-2">
          <HarnessIcon harness={id} muted={!detectedRoot} className="size-5" />
          {/* A harness that isn't installed has nothing to show, so only a
              detected one gets the button. */}
          {detectedRoot ? (
            <ShowEverythingButton
              name={name}
              onOpen={() => goToLibrary({ harness: id })}
            />
          ) : (
            <span className="text-sm font-medium text-muted-foreground">
              {name}
            </span>
          )}
          {version ? (
            <span className="font-mono text-xs text-muted-foreground">
              {version}
            </span>
          ) : null}
        </span>
        <span className="flex min-w-0 items-center gap-1 pl-7">
          <span
            className={cn(
              "truncate text-[13px] text-muted-foreground",
              detectedRoot && "font-mono",
            )}
          >
            {detectedRoot ?? NOT_INSTALLED_LABEL}
          </span>
          {/* One pencil per row is one too many to look at seven times
              over; it appears on the row the pointer is on, and stays for
              the keyboard. */}
          <Button
            variant="quiet"
            size="icon-xs"
            className="opacity-0 transition-opacity group-hover:opacity-100 focus-visible:opacity-100"
            aria-label={`Change where ${name} keeps its files`}
            title={HARNESS_FOLDER_HELP}
            onClick={() => setEditing(true)}
          >
            <Pencil className="size-3" />
          </Button>
        </span>
      </div>
      <HarnessFolderDialog
        open={editing}
        onOpenChange={setEditing}
        harness={name}
        folder={folder}
        detectedRoot={detectedRoot}
        onSave={onFolderChange}
      />
      {detectedRoot ? (
        <div className="flex shrink-0 flex-wrap justify-end gap-1.5 pt-0.5">
          <KindCountBadges
            counts={counts}
            onKindClick={(kind) => goToLibrary({ harness: id, kind })}
          />
        </div>
      ) : null}
    </div>
  );
}
