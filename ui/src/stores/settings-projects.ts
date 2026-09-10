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
}): ProjectsSlice {
  return {
    // Answers the registry write and nothing else. Reading what the
    // project holds is started here and deliberately not waited for: it is
    // a whole-machine read, and holding the caller behind it is what left
    // the add dialog on screen looking frozen. `project-setup.ts` carries
    // the two states that read has, and the card draws them.
    registerProject: async (path) => {
      const at = ordered.ticket();
      const response = await commands.registerProject(path);
      if (response.status === "ok") {
        ordered.hold(response.data.read, at);
        toast.success(`Added ${path.split("/").pop()}`);
        // The root the registry recorded, from the write itself. Never the
        // string the reader typed and never a difference against the list
        // before it: `register_project` expands a tilde and stores the
        // canonical path, and two rows added together from Find existing
        // projects each see both new entries, so no set difference can say
        // which one is its own.
        void useProjectSetupStore.getState().check(response.data.root);
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
