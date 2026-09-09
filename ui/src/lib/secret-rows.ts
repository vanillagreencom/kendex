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

/** Whether picking this file is a change the project does not already
 *  hold. Picking the file a project already names is no change at all, and
 *  neither is picking nothing. */
export function choosesFile(
  read: ScopeSettings | null,
  picked: string | null,
): boolean {
  return picked !== null && read?.secrets?.destination.chosen === false;
}

/** The secret half of a save, or null where this draft has none.
 *
 *  Two things put one here, and either alone is enough. A value typed into
 *  a field is one. Naming a private file the project does not already name
 *  is the other: the choice is written into `kendex.settings.toml` as the
 *  key both package loaders read, so it is a save of its own and not
 *  something a person has to type a credential to make stick. A pick that
 *  changes nothing sends nothing.
 *
 *  The base is the one the fields on screen were read with, so a private
 *  file that moved since is refused rather than written over. */
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
  if (!secrets) return null;
  const choose = choosesFile(read, picked);
  if (edits.length === 0 && !choose) return null;
  return {
    edits,
    file: secrets.destination.file,
    choose,
    base: secrets.base,
  };
}
