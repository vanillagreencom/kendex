import { Pencil } from "lucide-react";
import { useState } from "react";
import type { HarnessId, ItemKind } from "@/bindings";
import { HarnessIcon } from "@/components/harness-icon";
import { HarnessFolderDialog } from "@/components/harnesses/harness-folder-dialog";
import { ShowEverythingButton } from "@/components/harnesses/show-everything-button";
import { KindCountBadges } from "@/components/kind-count-badges";
import { Button } from "@/components/ui/button";
import {
  HARNESS_FOLDER_HELP,
  HARNESS_VERSION_HELP,
  harnessRootHelp,
  NOT_INSTALLED_LABEL,
  showKindLabel,
} from "@/lib/copy";
import type { ItemPlace } from "@/lib/derive";
import { harnessName, kindLabel } from "@/lib/labels";
import { opensLabel, opensOnActivate } from "@/lib/opens-on-activate";
import { cn } from "@/lib/utils";
import { useNavStore } from "@/stores/nav";

/** One detected (or missing) harness, as a single compact row.
 *
 * Where the harness keeps its files is the row's second line, and changing it
 * is a pencil on that line — a page-long second list of the same seven
 * harnesses, one "Set folder" button each, would say the same thing twice and
 * bury the fact that almost nobody needs it. */
export function HarnessRow({
  place,
  detectedRoot,
  version,
  counts,
  uncounted,
  folder,
  onFolderChange,
}: {
  /** What this row is a row of, in the form the Library takes: the same
   * object the counts were taken over, so every link below asks for the
   * set that was counted rather than a second description of it. */
  place: ItemPlace & { harness: HarnessId };
  detectedRoot: string | null;
  version: string | null;
  counts: [ItemKind, number][];
  /** Why the counts cannot be shown, or null when they can — the badges
   *  count packages, and the read that says which installations are one
   *  package answers separately from the scan. */
  uncounted?: string | null;
  /** The folder this harness was pointed at by hand, when it was. */
  folder: string;
  onFolderChange: (root: string) => void;
}) {
  const goToLibrary = useNavStore((s) => s.goToLibrary);
  const [editing, setEditing] = useState(false);
  const id = place.harness;
  const name = harnessName(id);

  const open = () => goToLibrary(place);

  return (
    // A harness that is not installed has nothing to show, so only a
    // detected row opens. The pencil and the count badges answer their own
    // clicks; everything else on the row opens the harness.
    <div
      {...(detectedRoot ? opensOnActivate(open, opensLabel(name)) : {})}
      className={cn(
        "group flex items-start justify-between gap-6 py-3.5",
        detectedRoot && "cursor-pointer",
      )}
    >
      <div className="flex min-w-0 flex-col gap-1">
        <span className="flex items-center gap-2">
          <HarnessIcon harness={id} muted={!detectedRoot} className="size-5" />
          {/* A harness that isn't installed has nothing to show, so only a
              detected one gets the button. */}
          {detectedRoot ? (
            <ShowEverythingButton name={name} onOpen={open} />
          ) : (
            <span className="text-sm font-medium text-muted-foreground">
              {name}
            </span>
          )}
          {/* A bare number beside a tool name could be anything it ships;
              the one word that says which is on hover. */}
          {version ? (
            <span
              className="font-mono text-xs text-muted-foreground"
              title={HARNESS_VERSION_HELP}
            >
              {version}
            </span>
          ) : null}
        </span>
        <span className="flex min-w-0 items-center gap-1 pl-7">
          {/* A path on its own line says nothing about whose it is or what
              it is for; the pencil beside it already answers that, and the
              line now answers it too. */}
          <span
            className={cn(
              "truncate text-[13px] text-muted-foreground",
              detectedRoot && "font-mono",
            )}
            title={detectedRoot ? harnessRootHelp(name) : undefined}
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
            describe={(kind, count) =>
              showKindLabel(count, kindLabel(kind, count), name)
            }
            uncounted={uncounted}
            onKindClick={(kind) => goToLibrary({ ...place, kind })}
          />
        </div>
      ) : null}
    </div>
  );
}
