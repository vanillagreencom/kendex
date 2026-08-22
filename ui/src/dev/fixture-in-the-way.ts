import type { DriftRow, RowExits, Scope } from "@/bindings";

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

/** The ways out core would report for the rows above. The shared folder
 *  sits at Claude Code's own place and Codex reads it through a shortcut,
 *  so only one of that pair can be entered — and one Keep covers both. A
 *  link is never written over, and a folder where a file goes is never
 *  kept as it stands. */
export const IN_THE_WAY_EXITS: RowExits[] = [
  row("skill:release-notes:claude", { keep: true, enter: true, replace: true }),
  row("skill:release-notes:codex", { keep: true, enter: true, replace: true }),
  row("hook:pre-commit:claude", { keep: true, enter: true, replace: true }),
  row("agent:scout:claude", { keep: false, enter: true, replace: true }),
  // One real folder at Claude Code's place, read by Codex through a
  // shortcut: kept through the tool that holds it, and never written over.
  row("skill:browser:claude", { keep: true, enter: true, replace: false }),
  row("skill:browser:codex", { keep: true, enter: false, replace: false }),
];

function row(
  key: string,
  exits: Pick<RowExits, "keep" | "enter" | "replace">,
): RowExits {
  const harness = key.split(":")[2] as RowExits["tools"][number];
  return { key, blocking: true, files: true, tools: [harness], ...exits };
}
