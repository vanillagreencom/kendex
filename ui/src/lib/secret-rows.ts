import type {
  ScopeSettings,
  SecretEdit,
  SecretRow,
  SkillSettings,
} from "@/bindings";

/** One skill's credential fields at the place being edited, empty where
 *  the place installs no such skill or its template could not be read. */
export function secretsIn(skill: SkillSettings | null): SecretRow[] {
  return skill?.template.state === "rows" ? skill.template.secrets : [];
}

export function secretEditIn(
  edits: SecretEdit[],
  skill: string,
  key: string,
): SecretEdit | undefined {
  return edits.find((edit) => edit.skill === skill && edit.key === key);
}

/** The edits after one more, replacing any earlier answer for the same
 *  key of the same skill — a save carries one answer per field, and two
 *  answers for one key is what core refuses the whole save over. */
export function withSecretEdit(
  edits: SecretEdit[],
  next: SecretEdit,
): SecretEdit[] {
  const at = edits.findIndex(
    (edit) => edit.skill === next.skill && edit.key === next.key,
  );
  if (at === -1) return [...edits, next];
  const out = edits.slice();
  out[at] = next;
  return out;
}

/** The edits without this field's answer: the person went back to leaving
 *  whatever is stored alone. */
export function withoutSecretEdit(
  edits: SecretEdit[],
  skill: string,
  key: string,
): SecretEdit[] {
  return edits.filter((edit) => !(edit.skill === skill && edit.key === key));
}

/** The secret half of a save, or null where this draft has none.
 *
 *  The base is the one the fields on screen were read with, so a private
 *  file that moved since is refused rather than written over. `choose` is
 *  the person having named a file this project does not already name,
 *  which the same save records so the packages read it too — a project
 *  saving into the default it always had records nothing. */
export function secretsDraft(
  edits: SecretEdit[],
  read: ScopeSettings | null,
  /** The file the person picked on this page, null while they have not. */
  picked: string | null,
): {
  edits: SecretEdit[];
  file: string;
  choose: boolean;
  base: string | null;
} | null {
  const secrets = read?.secrets;
  if (edits.length === 0 || !secrets) return null;
  return {
    edits,
    file: secrets.destination.file,
    choose: picked !== null && !secrets.destination.chosen,
    base: secrets.base,
  };
}
