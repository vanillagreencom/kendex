// Per-kind copy for the error modal and the persistent problems list — kept
// out of labels.ts so that file's routine product vocabulary doesn't have to
// carry this denser, failure-specific prose too.
import type { ProblemKind } from "@/stores/problems";

// Nothing converts a file from another version of kendex, so "old" and
// "damaged" reach these kinds together: a lock this build cannot read is
// lock-corrupt either way, and a manifest an older kendex wrote is
// manifest-outdated. The two are kept apart because the remedies differ —
// a lock is a cache to throw away, a manifest is what the person wrote.
//
// Both kinds arrive from Personal as readily as from a project, and no
// filename holds across the places they arrive from: the two scopes keep
// their locks under different names and their pi files under different
// roots, and a source catalog keeps its install state in kendex-local.toml
// while its kendex.toml is the catalog it publishes. So this copy names no
// path of its own: the card prints the error above these steps and the
// error carries the path, and the card's own heading says which place it
// is about.
export const PROBLEM_HEADLINES: Record<ProblemKind, string> = {
  "lock-corrupt": "A kendex file can't be read",
  "manifest-outdated": "This manifest comes from an older version",
  "schema-too-new": "This project's kendex files come from a newer version",
  "manifest-invalid": "This project's manifest has a problem",
  other: "Something went wrong in this project",
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
    "Open the file named above and check its syntax",
    "Rescan once it's fixed",
  ],
  other: [
    "Rescan to retry",
    "If it keeps failing, stop tracking this project and re-add it",
  ],
  "scan-failure": [
    "Try scanning again",
    "Check that kendex can still read your harness folders",
  ],
};

// Which file, and where. The engine's message names the exact path, but it
// names it inside a sentence written for a terminal; the card says the same
// thing first, in the words the reader already has for the place.
//
// Each lead names the file by what it is and never by its name, the rule
// the headings and steps above already hold to. No filename here is fixed:
// a scope's lock is `.kendex-lock.json` or `lock.json` by scope, and its
// manifest is `kendex.toml` except in a source catalog, where install state
// goes to `kendex-local.toml` (`manifest::file::manifest_path`) and the
// published `kendex.toml` is a different file entirely. A lead naming one
// sits directly above an error naming the other, and the steps then say to
// move "the file named above" with two candidates under it.
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
