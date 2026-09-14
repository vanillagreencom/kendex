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

// Nothing converts a file from an unsupported version of kendex, so an
// unreadable lock is lock-corrupt whether its bytes or schema cause the
// refusal. A manifest under a retired schema is manifest-outdated. The two
// are kept apart because the remedies differ — a lock is a cache to throw
// away, a manifest is what the person wrote.
export const PROBLEM_HEADLINES: Record<ProblemKind, string> = {
  "lock-corrupt": "kendex's install record can't be read",
  "manifest-outdated":
    "The file that lists what to install is from an older version of kendex",
  "schema-too-new": "These kendex files are from a newer version of kendex",
  "manifest-invalid": "The file listing what to install has a problem",
  other: "Something went wrong here",
  "scan-failure": "kendex couldn't scan this computer",
};

export const PROBLEM_STEPS: Record<ProblemKind, string[]> = {
  "lock-corrupt": [
    "Scan again",
    "If it still fails, the file named above is damaged or from an older version of kendex. Move it to another folder, then run kendex apply in a terminal to write a new one",
    "Keep the file you moved. It is the only record of a Pi hooks.json file or hooks/ folder in the same place, so move those to the other folder too",
  ],
  "manifest-outdated": [
    "Move the file named above to another folder. kendex does not convert it or change it",
    "Write what you want installed into a new file with the same name, then run kendex apply in a terminal. Copy what you need from the file you moved",
  ],
  "schema-too-new": [
    "Update kendex to the latest version",
    "Scan again after you update",
  ],
  "manifest-invalid": [
    "Open the file named above and make the fix the message names",
    "Scan again after you fix it",
  ],
  // Rescanning is the only move this copy can name. The other way out of a
  // failure with no known cause is the stop-tracking button, which the card
  // draws only where there is a project to stop tracking.
  other: ["Scan again"],
  "scan-failure": [
    "Scan again",
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
// an unsupported schema can be either file. A lead line there would be a guess.
export const PROBLEM_LEADS: Record<
  ProblemKind,
  ((place: string) => string) | null
> = {
  "lock-corrupt": (place) =>
    `The file is kendex's record of what it installed in ${place}.`,
  "manifest-outdated": (place) =>
    `The file is where ${place} lists what it wants installed.`,
  "manifest-invalid": (place) =>
    `The file is where ${place} lists what it wants installed.`,
  "schema-too-new": null,
  other: null,
  "scan-failure": null,
};

export const PROBLEMS_SUBTITLE =
  "What kendex can't fix without you, and what to do about each problem";
export const PROBLEMS_EMPTY = "No problems right now.";

/** The footer marker's words: what it counts, by class. */
export const attentionFooterLabel = (
  problems: number,
  decisions: number,
): string =>
  [
    problems > 0 ? `${problems} problem${problems === 1 ? "" : "s"}` : null,
    decisions > 0
      ? `${decisions} decision${decisions === 1 ? "" : "s"} waiting`
      : null,
  ]
    .filter((part) => part !== null)
    .join(", ");
