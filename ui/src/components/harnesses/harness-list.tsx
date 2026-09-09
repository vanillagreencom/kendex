import type { HarnessId } from "@/bindings";
import { HarnessRow } from "@/components/harnesses/harness-row";
import { Button } from "@/components/ui/button";
import { installedCountByKind } from "@/lib/derive";
import { CONTENT_WIDTH, PAGE_BODY } from "@/lib/layout";
import {
  packagesUncounted,
  usePackageIndex,
  usePackagesKnown,
  usePackagesRead,
} from "@/lib/package-identity";
import { useScanStore } from "@/stores/scan";
import { useSettingsStore } from "@/stores/settings";

const ALL_HARNESSES: HarnessId[] = [
  "claude",
  "codex",
  "opencode",
  "cursor",
  "pi",
  "gemini",
  "copilot",
  "antigravity",
];

/** "Harnesses": the AI coding tools this machine has, one row each. */
export function HarnessList() {
  const result = useScanStore((s) => s.result);
  const refreshScan = useScanStore((s) => s.refresh);
  const settings = useSettingsStore((s) => s.settings);
  const setHarnessRoot = useSettingsStore((s) => s.setHarnessRoot);
  const packageOf = usePackageIndex();
  // The badges count packages and their clicks open the Library on the same
  // narrowing, so both wait on the one read that says which installations
  // are one package.
  const uncounted = packagesUncounted(usePackagesKnown(), usePackagesRead());

  const anyDetected = ALL_HARNESSES.some((id) =>
    result?.harnesses.some((h) => h.harness === id),
  );

  if (result && !anyDetected) {
    return (
      <div className="flex flex-col items-center gap-2 py-16 text-center">
        <p className="font-medium">No AI coding tools found.</p>
        <p className="text-sm text-muted-foreground">
          Install Claude Code, Codex, OpenCode, Cursor, Pi, Gemini CLI, GitHub
          Copilot, or Antigravity and scan again.
        </p>
        <Button
          variant="outline"
          className="mt-2"
          onClick={() => void refreshScan({ announce: true })}
        >
          Scan again
        </Button>
      </div>
    );
  }

  const detected = (id: HarnessId) =>
    result?.harnesses.some((h) => h.harness === id) ?? false;
  const rows = [...ALL_HARNESSES].sort((a, b) =>
    detected(a) === detected(b) ? 0 : detected(a) ? -1 : 1,
  );

  return (
    <div className={PAGE_BODY}>
      <div className={CONTENT_WIDTH}>
        <div className="flex flex-col">
          {rows.map((id) => {
            const info = result?.harnesses.find((h) => h.harness === id);
            // The row's badges count what this harness holds, and its links
            // ask the Library for the same place — one object, so neither
            // can be narrowed without the other.
            const place = { harness: id };
            // No index means no count, which `uncounted` says in the
            // badges' place.
            const counts = packageOf
              ? installedCountByKind(result?.items ?? [], place, packageOf)
              : new Map();
            return (
              <HarnessRow
                key={id}
                place={place}
                uncounted={uncounted}
                detectedRoot={info?.root ?? null}
                version={info?.version ?? null}
                counts={[...counts.entries()]}
                folder={settings?.["harness-roots"]?.[id] ?? ""}
                onFolderChange={(root) => void setHarnessRoot(id, root)}
              />
            );
          })}
        </div>
      </div>
    </div>
  );
}
