import { Trash2 } from "lucide-react";
import { useState } from "react";
import type { Scope } from "@/bindings";
import { ConfirmDialog } from "@/components/confirm-dialog";
import { AddProjectDialog } from "@/components/harnesses/add-project-dialog";
import { ProjectCard } from "@/components/harnesses/project-card";
import { ScanFolderDialog } from "@/components/harnesses/scan-folder-dialog";
import { Button } from "@/components/ui/button";
import { unmanagedCount } from "@/lib/audit-counts";
import { countByKind } from "@/lib/derive";
import { CONTENT_WIDTH, PAGE_BODY } from "@/lib/layout";
import { sameScope } from "@/lib/scope";
import { cn } from "@/lib/utils";
import { useAuditOnMount, useAuditStore } from "@/stores/audit";
import { useNavStore } from "@/stores/nav";
import { useScanStore } from "@/stores/scan";
import { useSettingsStore } from "@/stores/settings";

const GLOBAL: Scope = { scope: "global" };

/** "Projects": personal plus every registered project, one card each. */
export function ProjectList() {
  useAuditOnMount();
  const result = useScanStore((s) => s.result);
  const views = useAuditStore((s) => s.views);
  // The audit read's own outcome: a failed adopt is not a failed audit, and
  // says so through the problems dialog rather than this list.
  const auditFailure = useAuditStore((s) => s.read.error);
  const goToLibrary = useNavStore((s) => s.goToLibrary);
  const goToUnmanaged = useNavStore((s) => s.goToUnmanaged);
  // What kendex is not looking after at one place. This is the only surface
  // in the app that mentions it: a count on the card for the place it is
  // at, and the flow that offers to take it on behind the click.
  // Null where the place could not be read; zero where the audit simply has
  // not reached it yet, which says nothing and will resolve on its own.
  const notManaged = (scope: Scope): number | null =>
    unmanagedCount(
      views.find((v) => sameScope(v.scope, scope)),
      auditFailure,
    );
  const { settings, registerProject, unregisterProject, discoverProjects } =
    useSettingsStore();
  const [removeTarget, setRemoveTarget] = useState<string | null>(null);
  const [adding, setAdding] = useState(false);
  const [scanning, setScanning] = useState(false);

  const globalItems =
    result?.items.filter((i) => i.scope.scope === "global") ?? [];
  const projects = settings?.projects ?? [];

  return (
    <div className={PAGE_BODY}>
      <div className={cn("flex flex-col gap-4", CONTENT_WIDTH)}>
        {/* Adding a project is a short errand, not part of reading the list
            — as a form pinned under the cards it took more of the page than
            the projects themselves. */}
        <div className="flex justify-end gap-2">
          <Button onClick={() => setAdding(true)}>Add a project</Button>
          <Button variant="outline" onClick={() => setScanning(true)}>
            Scan a folder
          </Button>
        </div>

        <ProjectCard
          name="Personal"
          subtitle="Works in every project on this computer"
          counts={[...countByKind(globalItems).entries()]}
          emptyLabel="Nothing from kendex yet."
          onOpen={() => goToLibrary({ scope: "global" })}
          onKindClick={(kind) => goToLibrary({ kind, scope: "global" })}
          unmanaged={notManaged(GLOBAL)}
          onUnmanaged={() => goToUnmanaged(GLOBAL)}
        />

        {projects.length === 0 ? (
          <p className="py-2 text-sm text-muted-foreground">
            No projects yet — add one to manage its tools.
          </p>
        ) : (
          projects.map((root) => {
            const items =
              result?.items.filter(
                (i) => i.scope.scope === "project" && i.scope.root === root,
              ) ?? [];
            const name = root.split("/").pop() ?? root;
            const scope: Scope = { scope: "project", root };
            return (
              <ProjectCard
                key={root}
                name={name}
                subtitle={root}
                path={root}
                counts={[...countByKind(items).entries()]}
                emptyLabel="Nothing from kendex yet."
                badge={
                  result?.missingProjects.includes(root)
                    ? "Folder not found"
                    : undefined
                }
                onOpen={() => goToLibrary({ scope: { project: root } })}
                onKindClick={(kind) =>
                  goToLibrary({ kind, scope: { project: root } })
                }
                unmanaged={notManaged(scope)}
                onUnmanaged={() => goToUnmanaged(scope)}
                action={
                  <Button
                    variant="ghost"
                    size="icon-sm"
                    aria-label={`Stop tracking ${name}`}
                    title={`Stop tracking ${name}`}
                    onClick={() => setRemoveTarget(root)}
                  >
                    <Trash2 className="size-4" />
                  </Button>
                }
              />
            );
          })
        )}

        <AddProjectDialog
          open={adding}
          onOpenChange={setAdding}
          registerProject={registerProject}
        />
        <ScanFolderDialog
          open={scanning}
          onOpenChange={setScanning}
          projects={projects}
          registerProject={registerProject}
          discoverProjects={discoverProjects}
        />
        <ConfirmDialog
          open={removeTarget !== null}
          onOpenChange={(open) => {
            if (!open) setRemoveTarget(null);
          }}
          title={`Stop tracking ${removeTarget?.split("/").pop() ?? ""}?`}
          description="kendex will stop managing this project. Nothing in the folder is deleted."
          confirmLabel="Stop tracking"
          destructive
          onConfirm={() => {
            if (removeTarget) void unregisterProject(removeTarget);
            setRemoveTarget(null);
          }}
        />
      </div>
    </div>
  );
}
