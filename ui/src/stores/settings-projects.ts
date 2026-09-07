// The project registry: the places kendex tracks beside the personal one,
// and the actions that add, drop and find them.
import { toast } from "sonner";
import { type AppSettings, commands, type SettingsRead } from "@/bindings";
import { rescanEverything } from "@/lib/rescan";
import { useProblemsStore } from "./problems";

interface ProjectFields {
  settings: AppSettings | null;
}

export interface ProjectsSlice {
  registerProject: (path: string) => Promise<boolean>;
  unregisterProject: (path: string) => Promise<void>;
  discoverProjects: (root: string) => Promise<string[]>;
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
    registerProject: async (path) => {
      const at = ordered.ticket();
      const response = await commands.registerProject(path);
      if (response.status === "ok") {
        ordered.hold(response.data, at);
        toast.success(`Added ${path.split("/").pop()}`);
        await rescanEverything();
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

    discoverProjects: async (root) => {
      const response = await commands.discoverProjects(root);
      if (response.status === "ok") return response.data;
      useProblemsStore.getState().showError({
        title: "Couldn't search that folder",
        message: response.error,
        steps: [
          "Check the folder path is correct",
          "Make sure kendex can read it",
        ],
      });
      return [];
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
