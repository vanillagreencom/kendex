import type { Scope } from "@/bindings";
import { Activity } from "@/components/activity";
import {
  HarnessSelect,
  isInstallable,
} from "@/components/marketplaces/harness-select";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Label } from "@/components/ui/label";
import {
  ALL_PROJECTS_LABEL,
  allProjectsHelp,
  INSTALL_ACTION,
  INSTALL_CANCEL,
  INSTALL_DONE,
  INSTALL_HELP,
  INSTALL_NO_PLACE,
  INSTALL_TITLE,
  INSTALL_TOOLS_LABEL,
  INSTALL_WHAT_LABEL,
  INSTALL_WHERE_LABEL,
  INSTALLING_LABEL,
  installedIn,
  installFailedIn,
  installsWhereItLives,
  NO_PROJECTS_TO_PICK,
  openPlaceLabel,
  PERSONAL_PLACE_HELP,
  packageCount,
  TOOLS_PER_PLACE,
} from "@/lib/copy-install";
import { selectionOf } from "@/lib/derive";
import { scopeName, scopeNames, scopePath } from "@/lib/labels";
import { scopeKey } from "@/lib/scope";
import {
  type InstallAsk,
  installablePlaces,
  picked,
  placeIsAChoice,
  togglePlace,
  useInstallFlow,
} from "@/stores/install-flow";
import { useNavStore } from "@/stores/nav";
import { useSettingsStore } from "@/stores/settings";
import { projectsOf } from "@/stores/settings-projects";

/** The one guided install, rendered once in App.tsx and opened by every
 *  Install in the app.
 *
 *  It reads top to bottom as one action: what is being installed, which
 *  places get it, the tools where that changes anything, and one button at
 *  the end. Four controls of equal weight in a header is what this
 *  replaces — a reader could not tell which of them was the action. */
export function InstallDialog() {
  const ask = useInstallFlow((s) => s.ask);
  if (!ask) return null;
  return <InstallFlow ask={ask} />;
}

function InstallFlow({ ask }: { ask: InstallAsk }) {
  const subjectId = useInstallFlow((s) => s.subjectId);
  const places = useInstallFlow((s) => s.places);
  const choice = useInstallFlow((s) => s.choice);
  const running = useInstallFlow((s) => s.running);
  const outcome = useInstallFlow((s) => s.outcome);
  const close = useInstallFlow((s) => s.close);
  const chooseSubject = useInstallFlow((s) => s.chooseSubject);
  const setPlaces = useInstallFlow((s) => s.setPlaces);
  const setChoice = useInstallFlow((s) => s.setChoice);
  const install = useInstallFlow((s) => s.install);
  const goToLibrary = useNavStore((s) => s.goToLibrary);
  const projects = useSettingsStore(projectsOf);

  const subject =
    ask.subjects.find((one) => one.id === subjectId) ?? ask.subjects[0];
  const offered = subject ? installablePlaces(subject, projects) : [];
  // What each place is called among the places beside it. Two projects can
  // end in the same folder, and this dialog states where files land.
  const names = scopeNames(offered);
  const nameOf = (place: Scope): string =>
    names[offered.findIndex((one) => scopeKey(one) === scopeKey(place))] ??
    scopeName(place);
  // Which tools take an install is a fact about one place. Across several
  // there is no single answer, so the question is not asked and each
  // place's own defaults decide — `TOOLS_PER_PLACE` says so.
  const onePlace = places.length === 1 ? places[0] : null;

  if (outcome) {
    return (
      <Dialog open onOpenChange={close}>
        <DialogContent className="sm:max-w-lg">
          <DialogHeader>
            <DialogTitle>{INSTALL_TITLE}</DialogTitle>
            <DialogDescription>
              {outcome.landed.length > 0
                ? installedIn(outcome.what, outcome.landed.map(nameOf))
                : installFailedIn(outcome.what, outcome.failed.map(nameOf))}
            </DialogDescription>
          </DialogHeader>
          {/* Both halves are said when both happened: a run into three
              places that lands in two is neither a success nor a failure,
              and naming only one of them would leave the reader to guess
              which places actually have the files. */}
          {outcome.landed.length > 0 && outcome.failed.length > 0 ? (
            <p className="text-sm text-critical" role="alert">
              {installFailedIn(outcome.what, outcome.failed.map(nameOf))}
            </p>
          ) : null}
          <DialogFooter>
            <Button variant="outline" onClick={close}>
              {INSTALL_DONE}
            </Button>
            {/* The way to the place that now has the package. The first
                place that landed, because that is the one the reader
                started from wherever they picked only one. */}
            {outcome.landed[0] ? (
              <Button
                onClick={() => {
                  const where = outcome.landed[0];
                  close();
                  goToLibrary({ scope: selectionOf(where) });
                }}
              >
                {openPlaceLabel(nameOf(outcome.landed[0]))}
              </Button>
            ) : null}
          </DialogFooter>
        </DialogContent>
      </Dialog>
    );
  }

  return (
    <Dialog open onOpenChange={(next) => !next && !running && close()}>
      <DialogContent className="max-h-[85vh] overflow-y-auto sm:max-w-lg">
        <DialogHeader>
          <DialogTitle>{INSTALL_TITLE}</DialogTitle>
          <DialogDescription>{INSTALL_HELP}</DialogDescription>
        </DialogHeader>

        <section className="space-y-2">
          <h3 className="text-[13px] font-medium">{INSTALL_WHAT_LABEL}</h3>
          {/* One answer is a statement, not a choice: a radio group of one
              asks a question that has already been settled. */}
          {ask.subjects.length === 1 && subject ? (
            <p className="text-[13px] text-muted-foreground">
              {subject.label} · {packageCount(subject.count)}
            </p>
          ) : (
            <div className="flex flex-col gap-2">
              {ask.subjects.map((one) => (
                <Label
                  key={one.id}
                  className="flex items-baseline gap-2 font-normal"
                >
                  <input
                    type="radio"
                    name="install-what"
                    aria-label={one.label}
                    className="accent-primary"
                    checked={one.id === subjectId}
                    disabled={running}
                    onChange={() => chooseSubject(one.id)}
                  />
                  <span>{one.label}</span>
                  <span className="text-xs text-muted-foreground">
                    {packageCount(one.count)}
                  </span>
                </Label>
              ))}
            </div>
          )}
        </section>

        <section className="space-y-2">
          <h3 className="text-[13px] font-medium">{INSTALL_WHERE_LABEL}</h3>
          {/* Only a personal subscription may send an install into another
              project, so a marketplace a project owns has one place and
              says why rather than drawing a picker with nothing to pick. */}
          {subject && !placeIsAChoice(subject) ? (
            <p className="text-[13px] text-muted-foreground">
              {installsWhereItLives(names)}
            </p>
          ) : (
            <PlacePicker
              offered={offered}
              names={names}
              places={places}
              disabled={running}
              onChange={setPlaces}
            />
          )}
        </section>

        {onePlace && subject ? (
          <section className="space-y-2">
            <h3 className="text-[13px] font-medium">{INSTALL_TOOLS_LABEL}</h3>
            <HarnessSelect
              scope={onePlace}
              kinds={subject.kinds}
              dependencies={subject.dependencies}
              value={choice}
              onChange={setChoice}
            />
          </section>
        ) : places.length > 1 ? (
          <p className="text-[13px] text-muted-foreground">{TOOLS_PER_PLACE}</p>
        ) : null}

        <DialogFooter>
          {/* Said where the button is, because it is the reason the button
              is off. */}
          {places.length === 0 ? (
            <p className="mr-auto text-[13px] text-muted-foreground">
              {INSTALL_NO_PLACE}
            </p>
          ) : null}
          {running ? (
            <Activity className="mr-auto" label={INSTALLING_LABEL} />
          ) : null}
          <Button variant="outline" disabled={running} onClick={close}>
            {INSTALL_CANCEL}
          </Button>
          <Button
            disabled={
              running ||
              places.length === 0 ||
              !subject ||
              // An empty tool list is a choice to install nowhere, which
              // reports success over a plan that wrote nothing.
              (onePlace !== null && !isInstallable(choice))
            }
            onClick={() => void install()}
          >
            {running ? INSTALLING_LABEL : INSTALL_ACTION}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

/** The places a personal subscription can install into, each with a box,
 *  and one box for every project at once. "All projects" is a real answer
 *  to the where question rather than a shortcut nobody can see the state
 *  of: it is ticked exactly when every project is. */
function PlacePicker({
  offered,
  names,
  places,
  disabled,
  onChange,
}: {
  offered: Scope[];
  names: string[];
  places: Scope[];
  disabled: boolean;
  onChange: (places: Scope[]) => void;
}) {
  const projects = offered.filter((one) => one.scope === "project");
  const allProjects =
    projects.length > 0 && projects.every((one) => picked(places, one));
  return (
    <div className="flex flex-col gap-2">
      {offered.map((place, index) => (
        <Label
          key={scopeKey(place)}
          className="flex items-baseline gap-2 font-normal"
        >
          {/* Named on the box itself: a label element around a button is
              not what names it, so read on its own the box would be one of
              several with nothing to tell them apart. */}
          <Checkbox
            aria-label={names[index]}
            checked={picked(places, place)}
            disabled={disabled}
            onCheckedChange={() =>
              onChange(togglePlace(offered, places, place))
            }
          />
          <span>{names[index]}</span>
          <span className="truncate font-mono text-xs text-muted-foreground">
            {scopePath(place) ?? PERSONAL_PLACE_HELP}
          </span>
        </Label>
      ))}
      {projects.length > 0 ? (
        <Label className="flex items-baseline gap-2 border-t pt-2 font-normal">
          <Checkbox
            aria-label={ALL_PROJECTS_LABEL}
            checked={allProjects}
            disabled={disabled}
            onCheckedChange={() =>
              onChange(
                allProjects
                  ? places.filter((one) => one.scope !== "project")
                  : offered.filter(
                      (one) => one.scope === "project" || picked(places, one),
                    ),
              )
            }
          />
          <span>{ALL_PROJECTS_LABEL}</span>
          <span className="text-xs text-muted-foreground">
            {allProjectsHelp(projects.length)}
          </span>
        </Label>
      ) : (
        <p className="text-[13px] text-muted-foreground">
          {NO_PROJECTS_TO_PICK}
        </p>
      )}
    </div>
  );
}
