import type { ItemKind, ObservedItem, Scope } from "@/bindings";
import { ProjectCard } from "@/components/package/project-card";
import { usePackagePlaces } from "@/components/package/use-package-places";
import { usePackageSetup } from "@/components/package/use-package-setup";
import { Section } from "@/components/section";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import {
  PROJECTS_EMPTY,
  PROJECTS_HEADING,
  PROJECTS_LOADING,
  REMOVE_ALL_LABEL,
  UPDATE_ALL_LABEL,
} from "@/lib/copy-projects";
import { INSTALL_ELSEWHERE_LABEL } from "@/lib/copy-setup";
import { selectionOf } from "@/lib/derive";
import { installElsewhere } from "@/lib/install-elsewhere";
import { packageDisplayName } from "@/lib/labels";
import { removablePlaces, updatableRows } from "@/lib/package-places";
import { scopeKey } from "@/lib/scope";
import { useAuditStore } from "@/stores/audit";
import { useInstallFlow } from "@/stores/install-flow";
import { useMarketplacesStore } from "@/stores/marketplaces";
import { useNavStore } from "@/stores/nav";
import { declaresSetup } from "@/stores/package-setup";
import { useProvenanceStore } from "@/stores/provenance";
import { useUpdatesStore } from "@/stores/updates";

/** One card per place, while the places are still being read. Two, because
 *  a single bar reads as a row that failed to load rather than as a list
 *  arriving. */
function ProjectsSkeleton() {
  return (
    <div
      role="status"
      aria-label={PROJECTS_LOADING}
      className="flex flex-col gap-3"
    >
      <Skeleton className="h-[4.5rem] w-full" />
      <Skeleton className="h-[4.5rem] w-full" />
    </div>
  );
}

/** The package page's Projects tab: every place this package is installed
 *  in, one card each, with the update, the removal and the repository
 *  setup that reach that place alone. Adding it to a project that lacks it
 *  is one link into the guided install, which is where the where question
 *  is asked — this tab lists the places the package is in, never every
 *  project on the machine.
 *
 *  Deleting every copy is not offered per card — it is one decision about
 *  the package, so it goes through the dialog `onDelete` opens. */
export function PackageProjects({
  kind,
  name,
  scopes,
  installations,
  busy,
  focus,
  onDelete,
}: {
  kind: ItemKind;
  name: string;
  scopes: Scope[];
  /** This package's installations, as the Library grouped them. */
  installations: ObservedItem[];
  busy: boolean;
  /** The place the reader was sent here to look at, from the Overview's
   *  setup summary, or null. Its card is marked and scrolled to, so a
   *  link that says "show me" lands on the row it meant rather than on a
   *  tab of cards. */
  focus: Scope | null;
  /** Absent where this page addresses no declaration. */
  onDelete?: () => void;
}) {
  const { places, loading, removalHeld } = usePackagePlaces(
    kind,
    name,
    scopes,
    installations,
  );
  const { entryFor, declares, recheck } = usePackageSetup(name, scopes);
  // The read is held to the same pair in `package-tabs.tsx`; asked here as
  // well because the rows are what would draw a state nothing read.
  const reportsSetup = declares && declaresSetup(kind);
  const updateOne = useUpdatesStore((s) => s.updateOne);
  const updateRows = useUpdatesStore((s) => s.updateRows);
  const removeItem = useAuditStore((s) => s.removeItem);
  const goToLibrary = useNavStore((s) => s.goToLibrary);
  const askToApply = useMarketplacesStore((s) => s.askToApply);
  const subscriptions = useMarketplacesStore((s) => s.rows);
  const provenance = useProvenanceStore((s) => s.rows);
  const openInstall = useInstallFlow((s) => s.open);
  const waiting = updatableRows(places);
  const removable = removablePlaces(places);
  const elsewhere = installElsewhere(
    kind,
    name,
    packageDisplayName({ kind, name }),
    provenance,
    subscriptions,
  );

  return (
    <Section
      title={PROJECTS_HEADING}
      action={
        loading ? null : (
          <span className="flex items-center gap-4">
            {/* Offered whether or not this package is installed anywhere:
                a package with no places left is the one most likely to
                want one. */}
            {elsewhere ? (
              <Button
                variant="link"
                size="sm"
                className="px-0"
                disabled={busy}
                onClick={() => openInstall({ subjects: [elsewhere] })}
              >
                {INSTALL_ELSEWHERE_LABEL}
              </Button>
            ) : null}
            {waiting.length > 0 ? (
              <Button
                variant="link"
                size="sm"
                className="px-0"
                disabled={busy}
                onClick={() => void updateRows(waiting)}
              >
                {UPDATE_ALL_LABEL}
              </Button>
            ) : null}
            {/* Held to the same judge as the cards: with nothing here
                kendex owns, there is no removal for this link to ask
                for. */}
            {removable.length > 0 && onDelete ? (
              <Button
                variant="link"
                size="sm"
                className="px-0"
                disabled={busy || removalHeld}
                onClick={onDelete}
              >
                {REMOVE_ALL_LABEL}
              </Button>
            ) : null}
          </span>
        )
      }
    >
      {loading ? (
        <ProjectsSkeleton />
      ) : places.length === 0 ? (
        <p className="text-sm text-muted-foreground">{PROJECTS_EMPTY}</p>
      ) : (
        <div className="flex flex-col gap-3">
          {places.map((place) => {
            const entry = entryFor(place.scope);
            const disclosure = entry?.setup?.disclosure ?? null;
            return (
              <ProjectCard
                key={scopeKey(place.scope)}
                place={place}
                busy={busy}
                removalHeld={removalHeld}
                focused={
                  focus !== null && scopeKey(focus) === scopeKey(place.scope)
                }
                setup={
                  reportsSetup && place.scope.scope === "project"
                    ? (entry ?? { setup: null, refused: null, reading: true })
                    : null
                }
                onOpen={() => goToLibrary({ scope: selectionOf(place.scope) })}
                onUpdate={() => place.row && void updateOne(place.row)}
                onRemove={() => void removeItem(place.scope, kind, name)}
                // Set up and Repair are the same yes: what changes is what
                // the reader was told about the state, and the dialog says
                // what will be written either way.
                onSetUp={() =>
                  disclosure && askToApply(place.scope, disclosure)
                }
                onCheckAgain={() => recheck(place.scope)}
              />
            );
          })}
        </div>
      )}
    </Section>
  );
}
