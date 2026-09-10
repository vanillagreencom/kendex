// The projects a write may be aimed at: the registered ones a scan read
// and found.
//
// A place kendex cannot reach takes no install. The plan for one is
// written against files under that folder, and every reading behind the
// choice — what is installed there, what it would land on — came from a
// read that found nothing because there was nothing to read. So the
// folder that could not be read is not offered as a destination, and the
// project's own card is where that is explained.
//
// With no reading at all this answers nothing rather than everything. An
// empty missing list read off a scan that has not landed is a claim made
// from silence: the folders it would clear are exactly the ones nobody
// has looked at yet, and a write aimed at one of them lands under a path
// this machine never confirmed. One judge answers for every surface that
// asks — the card's own actions, the empty state's button and the guided
// install's destinations — so none of them can hold a place the others
// offer.
import type { ScanResult } from "@/bindings";
import { useScanStore } from "@/stores/scan";
import { useSettingsStore } from "@/stores/settings";
import { projectsOf } from "@/stores/settings-projects";

/** Whether a scan opened this project's folder.
 *
 *  Asked of what the scan read, never of what it did not flag. A project
 *  registered since the last scan ran is missing from that scan's
 *  missing list exactly as a folder it opened is, so absence says
 *  nothing — and says nothing indefinitely where the read that would
 *  have covered it fails. A reading that failed leaves the last one
 *  standing, which is the same evidence every card draws from. */
export const placeIsReachable = (
  root: string,
  result: ScanResult | null,
): boolean => (result ? result.readProjects.includes(root) : false);

/** `projects` narrowed to the ones that reading found. */
export const reachableProjects = (
  projects: string[],
  result: ScanResult | null,
): string[] => projects.filter((root) => placeIsReachable(root, result));

/** The same list for code outside a component, read from the stores that
 *  hold both halves. */
export const reachableProjectsNow = (): string[] =>
  reachableProjects(
    projectsOf(useSettingsStore.getState()),
    useScanStore.getState().result,
  );

/** The same list in a component. */
export function useReachableProjects(): string[] {
  const projects = useSettingsStore(projectsOf);
  const result = useScanStore((s) => s.result);
  return reachableProjects(projects, result);
}
