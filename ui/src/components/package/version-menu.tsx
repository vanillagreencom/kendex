import { Check, ChevronDown, Pin } from "lucide-react";
import { useState } from "react";
import type { VersionRow } from "@/bindings";
import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import {
  COMPARE_WITH_INSTALLED_LABEL,
  FOLLOW_SOURCE_LABEL,
  HELD_VERSION_TAG,
  INSTALLED_VERSION_TAG,
  NO_VERSIONS_NOTE,
  SWITCH_VERSION_LABEL,
} from "@/lib/copy";
import { UPDATES_ONE_AT_A_TIME_NOTE } from "@/lib/copy-updates";
import { relativeTime } from "@/lib/relative-time";
import { installedRow, versionRowLabel } from "@/lib/versions";
import { useUpdatesStore } from "@/stores/updates";
import { useVersionsBusy } from "./use-package-data";

/** The version picker: every version of the package, newest first, the
 *  installed one marked. Picking a version selects it — the actions under
 *  the menu say what happens next, so a browse never installs anything. */
export function VersionMenu({
  versions,
  held,
  busy,
  onSwitch,
  onCompare,
  onFollow,
}: {
  versions: VersionRow[];
  /** The declaration holds a version (manual updates). */
  held: boolean;
  /** The page's manifest gate. A check is added here: these two commit
   *  through the updates store, so one must not run beside them. */
  busy: boolean;
  onSwitch: (row: VersionRow) => void;
  onCompare: (row: VersionRow) => void;
  onFollow: () => void;
}) {
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const running = useVersionsBusy(busy);
  // The check's half of that gate is the one this surface can name: the
  // rest is the page's own manifest work, which says so where it started.
  const waiting = useUpdatesStore((s) => s.checking);
  const installed = installedRow(versions);
  const selected =
    versions.find((row) => row.id === selectedId && !row.installed) ?? null;
  const current = installed ?? versions[0];

  if (versions.length === 0) {
    return <p className="text-sm text-muted-foreground">{NO_VERSIONS_NOTE}</p>;
  }

  return (
    <div className="space-y-2">
      <DropdownMenu>
        <DropdownMenuTrigger
          render={
            <Button size="sm" variant="outline">
              {held ? <Pin className="size-3.5" /> : null}
              {current ? versionRowLabel(current) : "—"}
              <ChevronDown className="size-3.5" />
            </Button>
          }
        />
        <DropdownMenuContent align="start" className="max-h-80 overflow-y-auto">
          {versions.map((row) => (
            <DropdownMenuItem
              key={row.id}
              onClick={() => setSelectedId(row.installed ? null : row.id)}
            >
              <span className="flex w-full items-center gap-2">
                {row.installed ? (
                  <Check className="size-3.5 shrink-0" />
                ) : (
                  <span className="w-3.5 shrink-0" />
                )}
                <span className="font-mono text-xs">
                  {versionRowLabel(row)}
                </span>
                <span className="min-w-0 flex-1 truncate text-xs text-muted-foreground">
                  {row.summary}
                </span>
                <span className="shrink-0 text-xs text-muted-foreground">
                  {row.installed
                    ? held
                      ? HELD_VERSION_TAG
                      : INSTALLED_VERSION_TAG
                    : relativeTime(Date.parse(row.date), Date.now())}
                </span>
              </span>
            </DropdownMenuItem>
          ))}
        </DropdownMenuContent>
      </DropdownMenu>

      {selected ? (
        <div className="space-y-2 rounded-lg border p-3">
          <p className="text-sm">
            <span className="font-mono text-xs">
              {versionRowLabel(selected)}
            </span>
            <span className="text-muted-foreground"> · {selected.summary}</span>
          </p>
          <div className="flex flex-wrap gap-2">
            <Button
              size="sm"
              disabled={running}
              title={waiting ? UPDATES_ONE_AT_A_TIME_NOTE : undefined}
              onClick={() => onSwitch(selected)}
            >
              {SWITCH_VERSION_LABEL}
            </Button>
            {installed ? (
              <Button
                size="sm"
                variant="outline"
                onClick={() => onCompare(selected)}
              >
                {COMPARE_WITH_INSTALLED_LABEL}
              </Button>
            ) : null}
          </div>
        </div>
      ) : null}

      {held ? (
        <Button
          size="sm"
          variant="ghost"
          disabled={running}
          title={waiting ? UPDATES_ONE_AT_A_TIME_NOTE : undefined}
          onClick={onFollow}
        >
          {FOLLOW_SOURCE_LABEL}
        </Button>
      ) : null}
    </div>
  );
}
