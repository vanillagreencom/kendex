// Per-kind copy for the error modal and the persistent problems list — kept
// out of labels.ts so that file's routine product vocabulary doesn't have to
// carry this denser, failure-specific prose too.
//
// Nothing here names a file whose name varies by place, and nothing here
// names the place. Both are the engine's to know: `manifest_path` and
// `lock_path` (crates/core/src/manifest/file.rs, crates/core/src/lock.rs)
// route a scope's manifest and lock by what that scope is, and every kind
// carrying a scope arrives from Personal as readily as from a project. The
// card already carries both — the engine's message names the exact path,
// and PlaceCard's name line under the heading names the place — so copy
// spelling out either can only contradict what the reader sees beside it.
// A lead names its file by role; a step points at the file named above.
//
// A name every place spells the same, like a harness's own hooks.json, is
// not one of those files and is free to appear. And scan-failure is the
// one kind with no scope to get wrong — it is about the machine rather
// than a place in it — so the scope half doesn't reach it; the guard in
// error-copy.test.ts exempts it by name.
import type { ProblemKind } from "@/stores/problems";

// Nothing converts a file from another version of kendex, so "old" and
// "damaged" reach these kinds together: a lock this build cannot read is
// lock-corrupt either way, and a manifest an older kendex wrote is
// manifest-outdated. The two are kept apart because the remedies differ —
// a lock is a cache to throw away, a manifest is what the person wrote.
export const PROBLEM_HEADLINES: Record<ProblemKind, string> = {
  "lock-corrupt": "A kendex file can't be read",
  "manifest-outdated": "This manifest comes from an older version",
  "schema-too-new": "These kendex files come from a newer version",
  "manifest-invalid": "This manifest has a problem",
  other: "Something went wrong here",
  "scan-failure": "kendex couldn't scan this machine",
};

export const PROBLEM_STEPS: Record<ProblemKind, string[]> = {
  "lock-corrupt": [
    "Rescan to retry",
    "If it keeps failing, the file named above is damaged or from an older version of kendex. Move it aside and apply again to write a fresh one",
    "Keep the file you moved. It is the only record naming a pi hooks.json or hooks/ beside the same root, so move those aside as well",
  ],
  "manifest-outdated": [
    "Move the file named above aside. Nothing converts it, and kendex leaves it exactly as you wrote it",
    "Declare what you want again and apply; the file you moved is there to copy from",
  ],
  "schema-too-new": [
    "Update kendex to the latest version",
    "Rescan once you're up to date",
  ],
  "manifest-invalid": [
    "Open the file named above and make the fix the message names",
    "Rescan once it's fixed",
  ],
  // Rescanning is the only move this copy can name. The other way out of a
  // failure with no known cause is the stop-tracking button, which the card
  // draws only where there is a project to stop tracking.
  other: ["Rescan to retry"],
  "scan-failure": [
    "Try scanning again",
    "Check that kendex can still read your harness folders",
  ],
};

// Which file, and where. The engine's message names the exact path, but it
// names it inside a sentence written for a terminal; the card says the same
// thing first, in the words the reader already has for the place. By role,
// never by name, per the rule in this file's header.
//
// Null where there is no one file to name — a scan failure is about no
// place at all, `other` is whatever the engine couldn't finish, and a
// too-new schema can be either file. A lead line there would be a guess.
export const PROBLEM_LEADS: Record<
  ProblemKind,
  ((place: string) => string) | null
> = {
  "lock-corrupt": (place) =>
    `The file is kendex's record of what it installed in ${place}.`,
  "manifest-outdated": (place) =>
    `The file is where ${place} declares what it wants installed.`,
  "manifest-invalid": (place) =>
    `The file is where ${place} declares what it wants installed.`,
  "schema-too-new": null,
  other: null,
  "scan-failure": null,
};

export const PROBLEMS_SUBTITLE =
  "What kendex can't finish on its own, and what to do about it";
export const PROBLEMS_EMPTY = "No problems right now.";

export const problemsFooterLabel = (count: number): string =>
  count === 1 ? "1 problem" : `${count} problems`;
