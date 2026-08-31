import type { Scope } from "@/bindings";

/** A scope as a stable key: "global", or the project root path. */
export const scopeKey = (scope: Scope): string =>
  scope.scope === "global" ? "global" : scope.root;

/** Whether two scopes are the same place. */
export const sameScope = (a: Scope, b: Scope): boolean =>
  scopeKey(a) === scopeKey(b);

/** Every place the app knows: the personal scope and each project, in the
 *  order the settings file names them. One definition — a surface that
 *  built the list itself would offer a different set of places than the
 *  one beside it. */
export const everyPlace = (projects: string[]): Scope[] => [
  { scope: "global" },
  ...projects.map((root) => ({ scope: "project" as const, root })),
];
