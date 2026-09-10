// The projects a write may be aimed at: the registered ones whose folder
// the last scan could read.
//
// A place kendex cannot reach takes no install. The plan for one is
// written against files under that folder, and every reading behind the
// choice — what is installed there, what it would land on — came from a
// read that found nothing because there was nothing to read. So the
// folder that could not be read is not offered as a destination, and the
// project's own card is where that is explained.
import type { MissingProject } from "@/bindings";
import { useScanStore } from "@/stores/scan";
import { useSettingsStore } from "@/stores/settings";
import { projectsOf } from "@/stores/settings-projects";

const NONE: MissingProject[] = [];

/** `projects` without the ones `missing` names. */
export const reachableProjects = (
  projects: string[],
  missing: MissingProject[],
): string[] =>
  missing.length === 0
    ? projects
    : projects.filter((root) => !missing.some((one) => one.root === root));

/** The same list for code outside a component, read from the stores that
 *  hold both halves. */
export const reachableProjectsNow = (): string[] =>
  reachableProjects(
    projectsOf(useSettingsStore.getState()),
    useScanStore.getState().result?.missingProjects ?? NONE,
  );

/** The same list in a component. */
export function useReachableProjects(): string[] {
  const projects = useSettingsStore(projectsOf);
  const missing = useScanStore((s) => s.result?.missingProjects ?? NONE);
  return reachableProjects(projects, missing);
}
