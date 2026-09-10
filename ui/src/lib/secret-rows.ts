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

/** This key's unsaved answer, whichever package's page it was typed on.
 *
 *  The key alone is the identity, because the key alone is what the file
 *  holds: one line, one value, however many packages declare it. Two
 *  packages declaring one key is a shape core allows on purpose, so a
 *  field showing an answer only on the page it was typed on would hide
 *  the pending value from the other page that writes the same line. */
export function secretEditIn(
  edits: SecretEdit[],
  key: string,
): SecretEdit | undefined {
  return edits.find((edit) => edit.key === key);
}

/** The edits after one more, replacing any earlier answer for the same
 *  key — a save carries one answer per key, and two answers for one key
 *  is what core refuses the whole save over. The package the new answer
 *  names replaces the old one as the declaration the write is checked
 *  against: it is the page the person last typed on, and either package
 *  declaring the key makes the write a legal one. */
export function withSecretEdit(
  edits: SecretEdit[],
  next: SecretEdit,
): SecretEdit[] {
  const at = edits.findIndex((edit) => edit.key === next.key);
  if (at === -1) return [...edits, next];
  const out = edits.slice();
  out[at] = next;
  return out;
}

/** The edits without this key's answer: the person went back to leaving
 *  whatever is stored alone. */
export function withoutSecretEdit(
  edits: SecretEdit[],
  key: string,
): SecretEdit[] {
  return edits.filter((edit) => edit.key !== key);
}

/** Whether picking this file is a change the project does not already
 *  hold and a save could actually make.
 *
 *  Three things have to hold. Somebody picked one; the project does not
 *  already name it; and the destination is one a value may go to. A
 *  refused destination is the last of those: core refuses the plan, so
 *  raising Save and promising to record the choice would promise a write
 *  that never happens. */
export function choosesFile(
  read: ScopeSettings | null,
  picked: string | null,
): boolean {
  const destination = read?.secrets?.destination;
  if (picked === null || !destination || destination.chosen) return false;
  return destination.state.state !== "refused";
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
