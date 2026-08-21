import type { DriftRow, Scope } from "@/bindings";

/** The mid-migration rows a repo moving onto kendex shows: files already
 *  where declarations go, in every shape the decision zone has to answer
 *  for. */
export function inTheWayDrift(acme: Scope): DriftRow[] {
  const ACME = acme.scope === "project" ? acme.root : "";
  return [
    // A repo being moved onto kendex: declared here, and the tool that
    // came before already left files where it goes. One item, two
    // tools, one decision — which is what the row folds to.
    {
      kind: "skill",
      name: "release-notes",
      harness: "claude",
      scope: acme,
      state: "conflict",
      cause: "unmanaged-content",
      detail: `${ACME}/.claude/skills/release-notes`,
    },
    {
      kind: "skill",
      name: "release-notes",
      harness: "codex",
      scope: acme,
      state: "conflict",
      cause: "unmanaged-content",
      detail: `${ACME}/.agents/skills/release-notes`,
    },
    // A kind adoption cannot take: one button, and the other way out
    // said in words instead of offered as an action that would fail.
    {
      kind: "hook",
      name: "pre-commit",
      harness: "claude",
      scope: acme,
      state: "conflict",
      cause: "unmanaged-content",
      detail: `${ACME}/.claude/hooks/pre-commit.sh`,
    },
    // A folder sitting where one file goes: replaceable, and the same
    // words for the other way out.
    {
      kind: "agent",
      name: "scout",
      harness: "claude",
      scope: acme,
      state: "conflict",
      cause: "unmanaged-wrong-shape",
      detail: `${ACME}/.claude/agents/scout.md`,
    },
    // One folder both tools read through shortcuts somebody set up:
    // keeping it is the only answer, and the row names the folder.
    {
      kind: "skill",
      name: "browser",
      harness: "claude",
      scope: acme,
      state: "conflict",
      cause: "shared-link",
      detail: `${ACME}/shared/browser`,
    },
    {
      kind: "skill",
      name: "browser",
      harness: "codex",
      scope: acme,
      state: "conflict",
      cause: "shared-link",
      detail: `${ACME}/shared/browser`,
    },
  ];
}

/** Every place adoption can be entered through. The shared folder sits at
 *  Claude Code's own place and Codex reads it through a shortcut, so only
 *  one of that pair is here — and one Keep covers both. */
export const IN_THE_WAY_KEEPABLE = [
  "skill:release-notes:claude",
  "skill:release-notes:codex",
  "hook:pre-commit:claude",
  "agent:scout:claude",
  "skill:browser:claude",
];
