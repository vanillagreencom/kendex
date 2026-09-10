// Saved package selections, as state.
//
// A template is the person's, not a place's: the list is the same
// everywhere in the app, so it is read once here and every surface reads
// it from here. Nothing in this file decides what a template may hold or
// what installing one writes — those are core's answers, reached through
// the commands.
import { create } from "zustand";
import {
  type Chosen,
  commands,
  type Draft_Serialize,
  type HarnessId,
  type Member_Deserialize,
  type MemberRef,
  type PackageFile,
  type Resolution,
  type Scope,
  type Template_Serialize,
} from "@/bindings";

/** How an install is delivered: one shared tree with links, or a copy per
 *  harness. The picker's answer, in the spelling the command takes. */
type Method = "symlink" | "copy";

import { writingRepo } from "@/lib/rescan";
import { settled } from "@/lib/settled";

export type Template = Template_Serialize;
export type Draft = Draft_Serialize;
export type Member = Member_Deserialize;

/** How a read stands: never started, out, answered, or failed with the
 *  reason. Kept apart from the rows so a failure over rows that landed
 *  earlier can head them as last-known rather than throwing them away. */
export type Read =
  | { status: "idle" }
  | { status: "reading" }
  | { status: "read" }
  | { status: "failed"; error: string };

interface TemplatesState {
  templates: Template[];
  /** Whether any answer has ever landed, which is what tells a failure
   *  with rows behind it from one with nothing. */
  everRead: boolean;
  read: Read;
  /** A write in flight, so a surface can hold its own buttons. */
  busy: boolean;
  /** What a write refused with, or null. Cleared when the next one starts.
   */
  refused: string | null;
  load: () => Promise<void>;
  createFromSelection: (name: string, members: Member[]) => Promise<boolean>;
  createFromProject: (project: string, chosen: Chosen) => Promise<boolean>;
  addMembers: (name: string, members: Member[]) => Promise<boolean>;
  removeMembers: (name: string, members: MemberRef[]) => Promise<boolean>;
  rename: (name: string, to: string) => Promise<boolean>;
  remove: (name: string) => Promise<boolean>;
  install: (name: string, destination: Scope) => Promise<boolean>;
  clearRefusal: () => void;
}

export const useTemplatesStore = create<TemplatesState>((set, get) => ({
  templates: [],
  everRead: false,
  read: { status: "idle" },
  busy: false,
  refused: null,

  load: async () => {
    set({ read: { status: "reading" } });
    const answer = await settled(commands.templatesList());
    if (answer.status === "error") {
      // The rows that landed before stay, headed as the last answer that
      // came back rather than thrown away over one read that did not.
      set({ read: { status: "failed", error: answer.error } });
      return;
    }
    set({ templates: answer.data, everRead: true, read: { status: "read" } });
  },

  createFromSelection: (name, members) =>
    write(set, get, () => commands.templateCreateFromSelection(name, members)),
  createFromProject: (project, chosen) =>
    write(set, get, () => commands.templateCreateFromProject(project, chosen)),
  addMembers: (name, members) =>
    write(set, get, () => commands.templateAddMembers(name, members)),
  removeMembers: (name, members) =>
    write(set, get, () => commands.templateRemoveMembers(name, members)),
  rename: (name, to) =>
    write(set, get, () => commands.templateRename(name, to)),
  remove: (name) => write(set, get, () => commands.templateDelete(name)),

  // An install writes into a place, so the machine is read again behind it
  // like every other write that reaches the engine.
  install: (name, destination) =>
    writingRepo(() =>
      write(set, get, () =>
        commands.templateInstall(name, destination, null, null),
      ),
    ),

  clearRefusal: () => set({ refused: null }),
}));

/** One write against the index: the refusal is kept where a surface can
 *  say it, and the list is read again whatever happened — a refusal is no
 *  account of what is saved. */
async function write<T>(
  set: (partial: Partial<TemplatesState>) => void,
  get: () => TemplatesState,
  body: () => Promise<
    { status: "ok"; data: T } | { status: "error"; error: string }
  >,
): Promise<boolean> {
  set({ busy: true, refused: null });
  const answer = await settled(body());
  set({ busy: false });
  if (answer.status === "error") set({ refused: answer.error });
  await get().load();
  return answer.status === "ok";
}

/** Install one template into one place, for the guided flow. Its own
 *  function rather than the store action so the flow can say why a place
 *  refused: the store keeps the last refusal for its own surfaces, and a
 *  run over several places needs one reason per place.
 *
 *  The machine is read again behind it like every other write that reaches
 *  the engine, and the list is read again because a template can be left
 *  standing by a refused install. */
export async function installTemplate(
  name: string,
  destination: Scope,
  delivery?: { harnesses: HarnessId[] | null; method: Method | null },
): Promise<{ ok: boolean; reason: string | null }> {
  const answer = await writingRepo(() =>
    settled(
      commands.templateInstall(
        name,
        destination,
        delivery?.harnesses ?? null,
        delivery?.method ?? null,
      ),
    ),
  );
  return answer.status === "ok"
    ? { ok: true, reason: null }
    : { ok: false, reason: answer.error };
}

/** What a template installs as it stands on this machine. Read on demand
 *  rather than held: it resolves marketplaces and reads the store, and a
 *  list of templates does not need any of that. */
export async function resolveTemplate(
  name: string,
): Promise<
  { status: "ok"; data: Resolution } | { status: "error"; error: string }
> {
  return settled(commands.templateResolve(name));
}

/** The files a template owns, for the tree that inspects its copies. */
export async function templateFiles(
  name: string,
): Promise<
  { status: "ok"; data: PackageFile[] } | { status: "error"; error: string }
> {
  return settled(commands.templateFiles(name));
}

/** One of those files, as text. */
export async function templateFile(
  name: string,
  path: string,
): Promise<
  { status: "ok"; data: string } | { status: "error"; error: string }
> {
  return settled(commands.templateFile(name, path));
}

/** The project's draft, read fresh every time the modal opens: what it
 *  offers is a reading of the project, and a held one would offer packages
 *  that have since gone. */
export async function templateDraft(
  project: string,
): Promise<{ status: "ok"; data: Draft } | { status: "error"; error: string }> {
  return settled(commands.templateDraft(project));
}

/** Templates by name, for a picker. A stable reference per store answer,
 *  because a selector minting an array re-renders for ever. */
export const templatesOf = (state: TemplatesState): Template[] =>
  state.templates;
