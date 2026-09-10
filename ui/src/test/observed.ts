import type { ObservedItem } from "@/bindings";

/** The separator between a shared file and the entry inside it, the way
 *  core spells it — a character no path and no command can hold. Written
 *  as an escape, never as the byte: a control character typed into a
 *  source file makes Git call the file binary. */
const ENTRY = "\u001f";

/** A fixture observation, with the identity the scan would have stamped on
 *  it.
 *
 *  `at` is a canonical path in production, which a fixture has no
 *  filesystem to resolve, so it is spelled here — once, for every fixture
 *  — rather than in each test beside its own path. Canonical means a link
 *  reads as what it points at, so two tools linking to one folder are one
 *  file here as well; a test that means two observations apart gives them
 *  two paths, which is the distinction the grouping is about. */
export const observed = (item: Omit<ObservedItem, "at">): ObservedItem => ({
  ...item,
  at: identityOf(item),
});

const identityOf = (item: Omit<ObservedItem, "at">): string => {
  if (item.fileState.state === "config-entry") {
    return `${item.path}${ENTRY}${item.action ?? ""}`;
  }
  return item.fileState.state === "symlink" && !item.fileState.broken
    ? item.fileState.target
    : item.path;
};
