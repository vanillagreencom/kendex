import { useMemo } from "react";
import type {
  HarnessId,
  ItemKind,
  ObservedItem,
  PackageRef,
  ProvenanceRow,
  Scope,
} from "@/bindings";
import { PLACE_COUNTING_LABEL, PLACE_UNCHECKED_LABEL } from "@/lib/copy";
import type { PackageIdentity } from "@/lib/derive";
import type { ReadState } from "@/lib/read-state";
import { scopeKey } from "@/lib/scope";
import { useProvenanceStore } from "@/stores/provenance";
import { useScanStore } from "@/stores/scan";

/** Which package one observed installation is, or null where nothing
 *  establishes that.
 *
 *  A tool stores a package in the shape it can load: a Cursor hook is an
 *  advisory rule, an OpenCode hook is a prefixed instruction file, a hook
 *  a tool runs is named for the event and command it registered, and a
 *  Codex command is a skill. Which of those is which package is settled in
 *  core off the records of what each install wrote — never here, and never
 *  off a name. */
export type PackageOf = (item: ObservedItem) => PackageRef | null;

/** The separator the join key is built from: a character a project root, a
 *  harness id, an item kind and a name all cannot hold, so no two
 *  installations run their parts together onto one key. Written as an
 *  escape and never as the byte itself — a NUL in a file's leading bytes
 *  makes Git call the file binary, and it is then unreviewable, unsearchable
 *  and unmergeable. */
const FIELD = "\u0000";

/** One installation, spelled the way both sides of the join spell it. */
const installationKey = (row: {
  scope: Scope;
  kind: ItemKind;
  name: string;
  harness: HarnessId;
}): string =>
  [scopeKey(row.scope), row.harness, row.kind, row.name].join(FIELD);

/** The identity every surface reads, out of the one join that carries it.
 *
 *  A row the join has no answer for — content a tool ships itself, or a
 *  read that has not landed — is left as what the scan saw. That keeps it
 *  distinct from everything else, which is the honest answer while nothing
 *  says otherwise. */
export function packageIndex(rows: ProvenanceRow[]): PackageOf {
  const byInstallation = new Map<string, PackageRef>();
  for (const row of rows) {
    if (row.package) byInstallation.set(installationKey(row), row.package);
  }
  return (item) => byInstallation.get(installationKey(item)) ?? null;
}

/** The same index for a component, rebuilt only when the join changes:
 *  every reader of a package's identity asks this one, so no two surfaces
 *  can key their rows differently. */
export function usePackageIndex(): PackageOf {
  const rows = useProvenanceStore((s) => s.rows);
  return useMemo(() => packageIndex(rows), [rows]);
}

/** Whether the identity of the scan ON SCREEN is known.
 *
 *  Not merely that a read once landed: the scan and the join answer
 *  separately, and a focus rescan or an in-app write publishes the new scan
 *  before its join has been asked for. Grouped against the previous
 *  answer, a package whose observed spelling just changed reads as one that
 *  is not installed — and the package page acts on that by leaving. So the
 *  question is whether the rows on hand answer about the scan on hand, and
 *  the two stores carry the one number that settles it.
 *
 *  A read that failed after one landed leaves this false, with the failure
 *  in {@link usePackagesRead} — the rows are last-known rather than an
 *  answer about now, which is exactly what a reader must be told.
 *
 *  Every surface counting in the package unit asks this one, so no two of
 *  them can draw a number the other would not. {@link identityCurrent} is
 *  the comparison itself, for anything holding the two numbers rather than
 *  subscribing to them. */
export const identityCurrent = (
  answeredFor: number | null,
  generation: number,
): boolean => answeredFor !== null && answeredFor === generation;

export const usePackagesKnown = (): boolean =>
  identityCurrent(
    useProvenanceStore((s) => s.answeredFor),
    useScanStore((s) => s.generation),
  );

/** Whether the join has ever answered at all, whatever it answered about.
 *  What tells a first read still on its way from one that failed over rows
 *  it had — the rows are last-known either way, and only this says there
 *  are any. */
export const usePackagesEverKnown = (): boolean =>
  useProvenanceStore((s) => s.loaded);

/** How the last read of the join went, for the surfaces that must tell a
 *  first read still on its way from one that failed. */
export const usePackagesRead = (): ReadState =>
  useProvenanceStore((s) => s.read);

/** Read the join again — what a failure's Try again does. */
export const useReloadPackages = (): (() => Promise<void>) =>
  useProvenanceStore((s) => s.reload);

/** Why a place's counts cannot be shown, or null when they can.
 *
 *  A badge counts packages and its click opens the Library on the same
 *  narrowing. Counted before the join answers, a hook installed for six
 *  tools reads as six entries under whichever kinds its files happen to
 *  be, and the click then lands on a shorter, differently-kinded list. A
 *  read still on its way and one that failed are different answers and
 *  neither is a number. */
export function packagesUncounted(
  known: boolean,
  read: ReadState,
): string | null {
  if (known) return null;
  return read.status === "failed"
    ? PLACE_UNCHECKED_LABEL
    : PLACE_COUNTING_LABEL;
}

/** Whether a page opened on this reference may address a declaration.
 *
 *  The one place that question is answered. A recorded package has a
 *  declaration behind it: its record, its versions, its Update, its
 *  enable switch and its Delete all speak to that declaration by scope,
 *  kind and name. An installation nothing recorded has none — and the very
 *  same scope, kind and name may belong to a package that does, so every
 *  one of those reads and writes would land on a different thing than the
 *  page describes. What such a page can still do is show the installation
 *  itself; taking it off the machine is the Not-managed path's, which
 *  addresses the file rather than a declaration.
 *
 *  Asked once, here, rather than as a flag beside each control: identity
 *  lost after a join is the class this whole issue is about, and a second
 *  copy of the rule is where it comes back. */
export const addressesDeclaration = (ref: {
  identity: PackageIdentity;
}): boolean => ref.identity === "recorded";
