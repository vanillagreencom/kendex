import type {
  ScopeSettings,
  SettingsEdit,
  SettingsRow,
  SkillSettings,
  SkillTemplate,
} from "@/bindings";

/** The keys a template declares, empty for every state that declares
 *  none. `invalid` is empty here and still says nothing about the
 *  settings file: seeding is lenient and may have written those keys
 *  anyway, which is why the page renders that state rather than a
 *  section with no rows in it. */
export function rowsOf(template: SkillTemplate): SettingsRow[] {
  return template.state === "rows" ? template.rows : [];
}

/** One skill's entry in a place's read, absent where the place has no
 *  settings file or does not install the skill. */
export function skillIn(
  read: ScopeSettings | null,
  skill: string,
): SkillSettings | null {
  if (!read?.applies) return null;
  return read.skills.find((one) => one.skill === skill) ?? null;
}

export function editIn(
  edits: SettingsEdit[],
  skill: string,
  key: string,
): SettingsEdit | undefined {
  return edits.find((edit) => edit.skill === skill && edit.key === key);
}

/** The edits after one more, replacing any earlier answer for the same
 *  key of the same skill — a save carries one answer per row, and two
 *  answers for one key is what core refuses the whole save over. */
export function withEdit(
  edits: SettingsEdit[],
  next: SettingsEdit,
): SettingsEdit[] {
  const at = edits.findIndex(
    (edit) => edit.skill === next.skill && edit.key === next.key,
  );
  if (at === -1) return [...edits, next];
  const out = edits.slice();
  out[at] = next;
  return out;
}

/** What the file will hold for this key once saved, or null where
 *  nothing readable assigns it. Only a `value` current is an answer: the
 *  other two say what is in the way instead of what the value is. */
export function effectiveValue(
  row: SettingsRow,
  edit?: SettingsEdit,
): string | null {
  if (edit) return edit.value.kind === "reset" ? row.default : edit.value.value;
  return row.current.state === "value" ? row.current.value : null;
}

/** Whether this key's value is not the package default. A fact about the
 *  file — the value may have been seeded, imported, or written by hand,
 *  and nothing here can say who put it there. */
export function differsFromDefault(
  row: SettingsRow,
  edit?: SettingsEdit,
): boolean {
  const value = effectiveValue(row, edit);
  return value !== null && value !== row.default;
}

/** Each place's skills whose settings file answers some key differently
 *  from the package default, keyed by scope.
 *
 *  A place absent from `reads` is absent from the map, and that is the
 *  whole point: the fact is unknown until its read lands, never false.
 *  A place that was read and holds nothing gets an empty set, which is
 *  an answer — global's `applies: false` resolves that way. `edits`
 *  never adds a place, only answers for one already read: a draft is
 *  not a read, and inventing a place from one would claim knowledge of
 *  a file nobody opened. */
export function settingsValues(
  reads: Record<string, ScopeSettings>,
  /** Unsaved edits by place, from a surface editing one of them. A
   *  place absent here simply has none in hand. */
  edits: Record<string, SettingsEdit[]> = {},
): ReadonlyMap<string, ReadonlySet<string>> {
  const out = new Map<string, ReadonlySet<string>>();
  for (const [where, read] of Object.entries(reads)) {
    const drafted = edits[where] ?? [];
    const differing = new Set<string>();
    for (const skill of read.skills)
      if (
        rowsOf(skill.template).some((row) =>
          differsFromDefault(row, editIn(drafted, skill.skill, row.key)),
        )
      )
        differing.add(skill.skill);
    out.set(where, differing);
  }
  return out;
}

/** The settings half of a save, or null where this draft has none. The
 *  base is the one the rows on screen were read with, so a file that
 *  moved since is refused rather than written over. */
export function settingsDraft(
  edits: SettingsEdit[],
  read: ScopeSettings | null,
): { edits: SettingsEdit[]; base: string | null } | null {
  if (edits.length === 0) return null;
  return { edits, base: read?.base ?? null };
}
