// The project registry: the places kendex tracks beside the personal one,
// and the actions that add, drop and find them.
import { toast } from "sonner";
import { type AppSettings, commands, type SettingsRead } from "@/bindings";
import { rescanEverything } from "@/lib/rescan";
import { useProblemsStore } from "./problems";
import { useProjectSetupStore } from "./project-setup";

interface ProjectFields {
  settings: AppSettings | null;
}

/** What a search of a folder came back with. A failure is its own answer,
 *  never an empty list: "no projects in there" is a claim about the folder,
 *  and a folder kendex could not read supports no claim at all — the
 *  dialog has to be able to tell the two apart to say which happened. */
export type Discovered =
  | { status: "found"; paths: string[] }
  | { status: "failed"; reason: string };

export interface ProjectsSlice {
  registerProject: (path: string) => Promise<boolean>;
  unregisterProject: (path: string) => Promise<void>;
  discoverProjects: (root: string) => Promise<Discovered>;
}

/** The project registry's actions. Registration and removal are targeted
 *  server-side writes, so they carry no base — but each reply is a written
 *  settings-plus-base pair, and holding it keeps the store's copy current
 *  for the next whole-file save. The hold comes from the store so every
 *  settings-holding reply shares one ticket order: a reply older than the
 *  newest one held is dropped, wherever it came from. */
export function projectActions(ordered: {
  ticket: () => number;
  hold: (read: SettingsRead, at: number) => void;
  /** The projects the store holds right now. A registry write answers with
   *  the whole list, and the root it added is the entry this one does not
   *  have — see [registeredRoot]. */
  projects: () => string[];
}): ProjectsSlice {
  return {
    // Answers the registry write and nothing else. Reading what the
    // project holds is started here and deliberately not waited for: it is
    // a whole-machine read, and holding the caller behind it is what left
    // the add dialog on screen looking frozen. `project-setup.ts` carries
    // the two states that read has, and the card draws them.
    registerProject: async (path) => {
      const at = ordered.ticket();
      // Read before the await, so the comparison below is against what
      // was tracked when this write was asked for.
      const before = ordered.projects();
      const response = await commands.registerProject(path);
      if (response.status === "ok") {
        ordered.hold(response.data, at);
        toast.success(`Added ${path.split("/").pop()}`);
        void useProjectSetupStore
          .getState()
          .check(registeredRoot(before, response.data, path));
        return true;
      }
      useProblemsStore.getState().showError({
        title: "Couldn't add the project",
        message: response.error,
        steps: [
          "Check the folder path is correct",
          "Make sure it isn't already added",
        ],
      });
      return false;
    },

    unregisterProject: async (path) => {
      const at = ordered.ticket();
      const response = await commands.unregisterProject(path);
      if (response.status === "ok") {
        ordered.hold(response.data, at);
        await rescanEverything();
      } else {
        useProblemsStore.getState().showError({
          title: "Couldn't stop tracking the project",
          message: response.error,
          steps: ["Try again"],
        });
      }
    },

    // The refusal is handed back rather than only shown behind the dialog
    // that asked: the search has a result panel of its own, and a failure
    // belongs in it beside the path that was searched and the button that
    // tries again.
    discoverProjects: async (root) => {
      const response = await commands.discoverProjects(root);
      if (response.status === "ok")
        return { status: "found", paths: response.data };
      return { status: "failed", reason: response.error };
    },
  };
}

/** The root the registry actually recorded for this request: the entry the
 *  fresh read holds that the previous one did not.
 *
 *  Never the string the reader typed. `register_project` expands a tilde
 *  and `settings::register_project` stores the canonical path, so `~/dev/acme`,
 *  a path with a trailing separator and a path through a symlink all land
 *  under a spelling the caller never saw — and the project's card matches
 *  its setup state against settings' own roots. Keyed on the typed string,
 *  the checking and check-failed states simply never appear for that
 *  project, and the card falls back to drawing it as empty.
 *
 *  Falls back to the request where the read names no new entry, which is
 *  what a reply that lost its ticket race leaves: the read behind it still
 *  runs, and the card shows the states it would have shown before. */
export function registeredRoot(
  before: string[],
  read: SettingsRead,
  asked: string,
): string {
  const had = new Set(before);
  return (read.settings.projects ?? []).find((root) => !had.has(root)) ?? asked;
}

// The answer before the settings read lands, shared rather than spelled at
// each call. A selector that wrote `[]` itself would mint a fresh array per
// snapshot, which React reads as a store that changed on every render: the
// tree holding it re-renders without ever settling.
const NO_PROJECTS: string[] = [];

/** The registered projects — empty until the settings read has landed. The
 *  empty answer is one shared array, so a component reading the list
 *  through this holds one identity across renders. */
export const projectsOf = (state: ProjectFields): string[] =>
  state.settings?.projects ?? NO_PROJECTS;
