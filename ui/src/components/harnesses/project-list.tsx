import { Trash2 } from "lucide-react";
import { useState } from "react";
import { ConfirmDialog } from "@/components/confirm-dialog";
import { AddProjectDialog } from "@/components/harnesses/add-project-dialog";
import { ProjectCard } from "@/components/harnesses/project-card";
import { ScanFolderDialog } from "@/components/harnesses/scan-folder-dialog";
import { Button } from "@/components/ui/button";
import { countByKind } from "@/lib/derive";
import { CONTENT_WIDTH, PAGE_BODY } from "@/lib/layout";
import { cn } from "@/lib/utils";
import { useNavStore } from "@/stores/nav";
import { useScanStore } from "@/stores/scan";
import { useSettingsStore } from "@/stores/settings";

/** "Projects": personal plus every registered project, one card each. */
export function ProjectList() {
  const result = useScanStore((s) => s.result);
  const setLibraryScope = useNavStore((s) => s.setLibraryScope);
  const goToLibrary = useNavStore((s) => s.goToLibrary);
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
          onOpen={() => {
            setLibraryScope("global");
            goToLibrary();
          }}
          onKindClick={(kind) => {
            setLibraryScope("global");
            goToLibrary({ kind });
          }}
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
            return (
              <ProjectCard
                key={root}
                name={name}
                subtitle={root}
                counts={[...countByKind(items).entries()]}
                emptyLabel="Nothing from kendex yet."
                badge={
                  result?.missingProjects.includes(root)
                    ? "Folder not found"
                    : undefined
                }
                onOpen={() => {
                  setLibraryScope({ project: root });
                  goToLibrary();
                }}
                onKindClick={(kind) => {
                  setLibraryScope({ project: root });
                  goToLibrary({ kind });
                }}
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
