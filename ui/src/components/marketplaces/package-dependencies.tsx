import type { InstallState, PackageDependencies } from "@/bindings";
import { Checkbox } from "@/components/ui/checkbox";
import { Label } from "@/components/ui/label";
import {
  DEPENDENCY_AMBIGUOUS_NOTE,
  DEPENDENCY_INSTALLED_NOTE,
  DEPENDENCY_NOT_OFFERED_NOTE,
  DEPENDENCY_REMOVED_NOTE,
  OPTIONAL_HEADING,
  OPTIONAL_NOTE,
  REQUIRES_HEADING,
  REQUIRES_NOTE,
} from "@/lib/copy-marketplaces";

/** What a dependency's state adds to its name, or nothing when it is
 *  simply on offer. A package already here is not installed twice, one the
 *  person removed stays removed until they add it back, one the catalog
 *  carries twice is one the engine will not choose between, and one it no
 *  longer carries cannot be installed at all — each a fact about the row,
 *  said beside it and never blamed on the wrong party. */
export function dependencyNote(state: InstallState): string | null {
  if (state === "installed") return DEPENDENCY_INSTALLED_NOTE;
  if (state === "removed-by-you") return DEPENDENCY_REMOVED_NOTE;
  if (state === "offered-more-than-once") return DEPENDENCY_AMBIGUOUS_NOTE;
  if (state === "available") return null;
  return DEPENDENCY_NOT_OFFERED_NOTE;
}

/** A dependency the install cannot take: the catalog no longer offers it,
 *  offers it under more than one plugin and will not guess, or the person
 *  removed it themselves and that removal is recorded — the engine keeps
 *  each of those out of every plan, so ticking it here would ask for
 *  something no install brings. */
const unavailable = (state: InstallState): boolean =>
  state === "not-offered" ||
  state === "removed-by-you" ||
  state === "offered-more-than-once";

/** The package page's dependency facts: what comes with this package, and
 *  what it offers to bring. Read-only — the choosing happens in the install
 *  picker, beside the button that acts on it. */
export function DependencyFacts({
  dependencies,
}: {
  dependencies: PackageDependencies;
}) {
  return (
    <>
      {dependencies.required.length > 0 ? (
        <section>
          <h3 className="mb-1 text-xs font-semibold text-muted-foreground uppercase">
            {REQUIRES_HEADING}
          </h3>
          <ul className="space-y-0.5">
            {dependencies.required.map((dep) => (
              <li key={dep.name}>
                {dep.shown}
                <DependencyNote state={dep.state} />
              </li>
            ))}
          </ul>
        </section>
      ) : null}
      {dependencies.optional.length > 0 ? (
        <section>
          <h3 className="mb-1 text-xs font-semibold text-muted-foreground uppercase">
            {OPTIONAL_HEADING}
          </h3>
          <ul className="space-y-0.5">
            {dependencies.optional.map((dep) => (
              <li key={dep.name}>
                {dep.shown}
                <DependencyNote state={dep.state} />
              </li>
            ))}
          </ul>
        </section>
      ) : null}
    </>
  );
}

/** The install picker's dependency block: what this install takes whatever
 *  anyone does, and a box per optional extra — every one of them off until
 *  it is ticked, which is what the manifest then records. */
export function DependencyChoice({
  dependencies,
  chosen,
  onChange,
}: {
  dependencies: PackageDependencies;
  /** The optional dependencies ticked so far, by declared name. */
  chosen: string[];
  onChange: (chosen: string[]) => void;
}) {
  const toggle = (name: string) =>
    onChange(
      chosen.includes(name)
        ? chosen.filter((held) => held !== name)
        : [...chosen, name],
    );
  return (
    <div className="mt-3 border-t pt-3">
      {dependencies.required.length > 0 ? (
        <>
          <p className="pb-2 text-xs text-muted-foreground">
            {REQUIRES_HEADING} — {REQUIRES_NOTE}
          </p>
          <ul className="pb-2">
            {dependencies.required.map((dep) => (
              <li key={dep.name}>
                {dep.shown}
                <DependencyNote state={dep.state} />
              </li>
            ))}
          </ul>
        </>
      ) : null}
      {dependencies.optional.length > 0 ? (
        <>
          <p className="pb-2 text-xs text-muted-foreground">
            {OPTIONAL_HEADING} — {OPTIONAL_NOTE}
          </p>
          <div className="flex flex-col gap-2">
            {dependencies.optional.map((dep) => (
              <Label
                key={dep.name}
                className="flex items-center gap-2 font-normal"
              >
                <Checkbox
                  checked={chosen.includes(dep.name)}
                  // A name the catalog cannot place installs nothing, so
                  // the box that would ask for it does not open.
                  disabled={unavailable(dep.state)}
                  onCheckedChange={() => toggle(dep.name)}
                />
                {dep.shown}
                <DependencyNote state={dep.state} />
              </Label>
            ))}
          </div>
        </>
      ) : null}
    </div>
  );
}

function DependencyNote({ state }: { state: InstallState }) {
  const note = dependencyNote(state);
  if (!note) return null;
  return <span className="ml-1.5 text-xs text-muted-foreground">{note}</span>;
}
