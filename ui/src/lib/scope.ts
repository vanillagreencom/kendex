import type { Scope } from "@/bindings";

/** A scope as a stable key: "global", or the project root path. */
export const scopeKey = (scope: Scope): string =>
  scope.scope === "global" ? "global" : scope.root;

/** Whether two scopes are the same place. */
export const sameScope = (a: Scope, b: Scope): boolean =>
  scopeKey(a) === scopeKey(b);

// Roots are serialized by the OS that wrote them, so a Windows project
// arrives with backslashes; either separator ends a folder name.
const pathParts = (root: string): string[] =>
  root.split(/[\\/]+/).filter((part) => part !== "");

/** The shortest trailing run of folders no other project among `among`
 *  ends with — one folder when nothing clashes, the whole root when even
 *  that is shared, so ~/work/app and ~/clients/app never read as one
 *  place twice. */
export function projectTail(root: string, among: Scope[]): string {
  const parts = pathParts(root);
  const others = among.flatMap((other) =>
    other.scope === "project" && other.root !== root
      ? [pathParts(other.root)]
      : [],
  );
  for (let take = 1; take <= parts.length; take += 1) {
    const suffix = parts.slice(-take).join("/");
    if (!others.some((other) => other.slice(-take).join("/") === suffix))
      return suffix;
  }
  return root;
}
