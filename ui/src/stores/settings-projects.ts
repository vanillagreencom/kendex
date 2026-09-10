// The project registry: the places kendex tracks beside the personal one,
// and the actions that add, drop and find them.
import { toast } from "sonner";
import {
  type AppSettings,
  commands,
  type Relocation,
  type SettingsRead,
} from "@/bindings";
import { rescanEverything } from "@/lib/rescan";
import { useCommitOfferStore } from "./commit-offer";
import { useNavStore } from "./nav";
import { useProblemsStore } from "./problems";
import { useProjectSetupStore } from "./project-setup";
import { useUpdatesStore } from "./updates";

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
  /** What reconnecting this project to that folder would mean, before
   *  anything is written. Null where the question itself could not be
   *  answered, which is reported where every other read failure is. */
  projectRelocation: (from: string, to: string) => Promise<Relocation | null>;
  /** Point the project at the folder it moved to. Answers with the folder
   *  the entry now names, or null where the write was refused. */
  relocateProject: (
    from: string,
    to: string,
    consolidate: boolean,
  ) => Promise<string | null>;
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

    // The registry write, then what the window filed under that folder —
    // the same drop the reconnect makes, for the same reason: a read still
    // out for it and an offer waiting on files in it are questions about a
    // place nothing tracks now, and reading the machine again answers
    // about places rather than about what the window filed under a name.
    unregisterProject: async (path) => {
      const at = ordered.ticket();
      const response = await commands.unregisterProject(path);
      if (response.status === "ok") {
        ordered.hold(response.data, at);
        useProjectSetupStore.getState().forget(path);
        useCommitOfferStore.getState().forget(path);
        await Promise.all([rescanEverything(), updatesAgain()]);
      } else {
        useProblemsStore.getState().showError({
          title: "Couldn't stop tracking the project",
          message: response.error,
          steps: ["Try again"],
        });
      }
    },

    projectRelocation: async (from, to) => {
      const response = await commands.projectRelocation(from, to);
      if (response.status === "ok") return response.data;
      useProblemsStore.getState().showError({
        title: "Couldn't check that folder",
        message: response.error,
        steps: ["Try again", "Choose a different folder"],
      });
      return null;
    },

    // The registry write, and then everything the window was holding about
    // the folder the project left. Those are answers about a path nothing
    // tracks any more — a read still out for it, an offer waiting on files
    // in it, a page the reader can go Back to — and none of them is
    // corrected by reading the machine again, which answers about places
    // rather than about what the window filed under a name.
    relocateProject: async (from, to, consolidate) => {
      const at = ordered.ticket();
      const response = await commands.relocateProject(from, to, consolidate);
      if (response.status !== "ok") {
        useProblemsStore.getState().showError({
          title: "Couldn't reconnect the project",
          message: response.error,
          steps: ["Choose the folder the project is in now"],
        });
        return null;
      }
      const { was, root } = response.data;
      ordered.hold(response.data.read, at);
      useProjectSetupStore.getState().forget(was);
      useCommitOfferStore.getState().forget(was);
      useNavStore.getState().projectMoved(was);
      // Through the project-setup owner, the way a registration's read
      // goes: it marks the new root checking and, where the read fails,
      // unchecked. A bare rescan leaves the card with neither — the kept
      // scan has no missing entry for the new root and no evidence it
      // read one either — and the card falls through to "Nothing from
      // kendex yet" over a folder nothing answered for.
      await Promise.all([
        useProjectSetupStore.getState().check(root),
        updatesAgain(),
      ]);
      return root;
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

/** The update standing again, on a registry write.
 *
 *  `rescanEverything` is the scan, the audit and the provenance join, and
 *  says so: what a package's source has moved on to is a fourth read,
 *  held by its own store and keyed by the place each row is at. Left
 *  alone across a reconnect every row still names the folder the project
 *  left, so the card at the new folder shows no updates — a definite
 *  nothing, from rows about a place that is not there — and the Updates
 *  page's own actions still name the old one. */
const updatesAgain = (): Promise<void> => useUpdatesStore.getState().reload();

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
