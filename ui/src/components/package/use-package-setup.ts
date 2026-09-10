import { useEffect, useRef } from "react";
import type { Scope } from "@/bindings";
import { scopeKey } from "@/lib/scope";
import { useMarketplacesStore } from "@/stores/marketplaces";
import {
  type SetupEntry,
  setupAt,
  usePackageSetupStore,
} from "@/stores/package-setup";

/** What each of a package's places says about its setup, and whether this
 *  package declares one at all.
 *
 *  A selector and nothing else: taking a status can mean running the
 *  package's own script, so what starts a read is [`usePackageSetupRead`],
 *  mounted once for the page. Two surfaces read this — the Projects tab's
 *  rows and the Overview's summary line — and they answer from the same
 *  entries, so they never disagree and the check runs once for both.
 *
 *  Whether the package declares an effect is one fact about the package,
 *  not one per place, so one place that ANSWERED and named a state is the
 *  whole answer. A place whose read failed is not: it read neither the
 *  declaration nor the repository, and treating its silence as a
 *  declaration would draw a setup row on every package whose command
 *  refused. Until a place answers, nothing is drawn — almost every
 *  package is inert, and flashing a Checking row over each of them says
 *  something false about all but a few.
 *
 *  The personal place is not one of these. Repository setup is a fact
 *  about a repository, and the personal setup is not one — so it is
 *  filtered before anything is asked rather than after, and its card
 *  carries no setup row at all. [`repositories`] is that filter, shared
 *  with the reader below so the two can never disagree about which places
 *  were asked. */
export function usePackageSetup(
  name: string,
  scopes: Scope[],
): {
  entryFor: (scope: Scope) => SetupEntry | undefined;
  declares: boolean;
  recheck: (scope: Scope) => void;
} {
  const entries = usePackageSetupStore((s) => s.entries);
  const check = usePackageSetupStore((s) => s.check);
  const answered = repositories(scopes)
    .map((scope) => setupAt(entries, scope, name))
    .filter((entry) => entry !== undefined && !entry.reading);
  return {
    // Undefined for the personal place, which draws no setup row: it was
    // never asked, and an entry it never had is what says so.
    entryFor: (scope) =>
      scope.scope === "project" ? setupAt(entries, scope, name) : undefined,
    declares: answered.some(
      (entry) =>
        entry?.setup != null && entry.setup.status.state !== "notDeclared",
    ),
    // Somebody pressed the control, so the package is asked directly
    // whether or not kendex recorded arming the effect here. That is the
    // route to a true answer in a repository armed at a terminal or by
    // hand, and the reason the row says what the button will do.
    recheck: (scope) => void check(scope, name, "person"),
  };
}

/** The places a repository setup can be a fact about: the projects.
 *
 *  The personal place is a card on the same tab — a package installed
 *  personally and in a project shows both — and a repository effect
 *  changes no repository there. Asking about it returned a state, which
 *  the card then had to word; not asking is the simpler answer and the one
 *  the issue states, that personal installation alone establishes nothing
 *  about any project. */
export const repositories = (scopes: Scope[]): Scope[] =>
  scopes.filter((scope) => scope.scope === "project");

/** Start the reads the two surfaces above draw from. Mounted once, by the
 *  page that owns both.
 *
 *  Two rules hold this together, and both exist because taking a status
 *  can mean running the package's own script.
 *
 *  It reads when the page asks: on open, on a change of package or of the
 *  set of places, and once the repository-effects dialog this page opened
 *  has been answered for. Never on the whole-machine rescan — that runs
 *  behind every write in the app, and a status is a script.
 *
 *  It reads again after that dialog closes whatever the answer was.
 *  Declining leaves the repository as it was and the check confirms that;
 *  applying changes it and the check is what says so. An installer that
 *  exits saying it skipped its work is not proof of anything, so nothing
 *  here reads the run's own result.
 *
 *  A null `name` is a page with no declaration behind it: there is no
 *  setup to read, and asking under a name this page does not own would run
 *  the scripts of whatever package does. */
export function usePackageSetupRead(
  name: string | null,
  scopes: Scope[],
): void {
  const checkAll = usePackageSetupStore((s) => s.checkAll);
  const forget = usePackageSetupStore((s) => s.forget);
  // The line of repository-effect questions, at the store rather than at
  // this page's own call: the dialog is mounted once for the app, and a
  // question this page raised is answered there.
  const asking = useMarketplacesStore((s) => s.pendingEffects !== null);
  // Which package and which places, not which array: the scan rebuilds
  // the group on every read. The personal place is not among them.
  const asked = repositories(scopes);
  const subject = `${name}|${asked.map(scopeKey).join("|")}`;
  const shown = useRef<string | null>(null);
  const wasAsking = useRef(asking);

  // biome-ignore lint/correctness/useExhaustiveDependencies: which package and which places, not which array
  useEffect(() => {
    // A different package's places are a different package's answers, and
    // an entry key carries only the place — so the record is emptied
    // rather than left to be read under the new name.
    if (shown.current !== subject) {
      shown.current = subject;
      forget();
    }
    if (name !== null) void checkAll(asked, name);
  }, [subject, checkAll, forget, name]);

  // biome-ignore lint/correctness/useExhaustiveDependencies: the closing of the line is the signal, not the places
  useEffect(() => {
    const closed = wasAsking.current && !asking;
    wasAsking.current = asking;
    if (closed && name !== null) void checkAll(asked, name);
  }, [asking, checkAll, name]);
}
