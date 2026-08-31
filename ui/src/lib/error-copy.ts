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
// Both kinds arrive from Personal as readily as from a project, and the
// two scopes keep their locks under different names and their pi files
// under different roots. So this copy names no path of its own: the card
// prints the error above these steps and the error carries the path, and
// the card's own heading says which place it is about.
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
    "Open the project's kendex.toml and check its syntax",
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

export const PROBLEMS_SUBTITLE =
  "What kendex can't finish on its own, and what to do about it";
export const PROBLEMS_EMPTY = "No problems right now.";

export const problemsFooterLabel = (count: number): string =>
  count === 1 ? "1 problem" : `${count} problems`;
