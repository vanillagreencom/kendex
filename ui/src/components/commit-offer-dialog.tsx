import { CheckIcon, CopyIcon } from "lucide-react";
import { useEffect, useState } from "react";
import type { ProjectOffer, Refused, TangledFile } from "@/bindings";
import { ExternalLink } from "@/components/external-link";
import { changeEntries } from "@/components/project-changes/change-rows";
import { ChangedFiles } from "@/components/project-changes/changed-files";
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
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { useMayAsk } from "@/lib/asks-first";
import {
  ACCEPT_EARLIER_HELD,
  ACCEPT_EARLIER_LABEL,
  ACTION_SEGMENT,
  ALL_SEGMENT,
  actionScopeNote,
  addsToPullRequest,
  allScopeNote,
  BRANCH_REFUSED_LINE,
  BRANCH_REFUSED_TITLE,
  BRANCH_ROW_LABEL,
  backOn,
  branchIsOn,
  COMMIT_AGAIN_LABEL,
  COMMIT_LABEL,
  COMMIT_OFFER_STANDING,
  COMMIT_ROW_LABEL,
  COMMIT_SEGMENT,
  COMMIT_STAYS,
  COMMITTING_LABEL,
  carriesEarlier,
  commitIsOn,
  commitOfferTitle,
  commitOn,
  commitRefusedTitle,
  DONE_LABEL,
  declaresWhatChanged,
  didNotFinish,
  FILES_LABEL,
  LEAVE_IT_HERE_LABEL,
  LEAVE_LABEL,
  MANIFEST_LEFT_LABEL,
  MESSAGE_LABEL,
  manifestLeft,
  NOT_PUT_BACK_LINE,
  NOT_PUT_BACK_TITLE,
  NOTHING_TO_COMMIT_TOAST,
  nowOn,
  OPEN_PR_LABEL,
  OPENING_LABEL,
  OTHER_LABEL,
  otherNote,
  PR_LABEL,
  PR_OPEN_TITLE,
  PR_ROW_LABEL,
  PR_SEGMENT,
  PUSH_LABEL,
  PUSH_ROW_LABEL,
  PUSH_SEGMENT,
  PUSHING_LABEL,
  prMoves,
  pullRequestRefusedTitle,
  pushesTo,
  pushRefusedTitle,
  putBackRowLabel,
  remoteBranch,
  resetCommand,
  SCAN_FAILED_STEPS,
  SCAN_FAILED_TITLE,
  SHARED_LABEL,
  SHARED_NOTE,
  saidLabel,
  stillCarries,
  stillStaged,
  TANGLED_LABEL,
  unavailableReason,
  WHAT_TO_DO_LABEL,
  WHICH_CHANGES_LABEL,
} from "@/lib/copy-commit-offer";
import { cn } from "@/lib/utils";
import {
  type Route,
  ready,
  routesFor,
  type Scoped,
  type Stage,
  useCommitOfferStore,
} from "@/stores/commit-offer";
import { useProblemsStore } from "@/stores/problems";

/** The question a kendex write leaves behind, rendered once in App.tsx:
 *  what to do with the files kendex wrote in this repository. One project
 *  at a time, each with its own answer, in the order the write reached
 *  them. Dismissing it is leaving the files as diffs — a choice of the
 *  same standing as the other three, and a success rather than a refusal. */
export function CommitOfferDialog() {
  const offer = useCommitOfferStore((s) => s.queue[0]);
  const stage = useCommitOfferStore((s) => s.stage);
  const leave = useCommitOfferStore((s) => s.leave);
  // Last of the three questions a write leaves behind — `lib/asks-first.ts`
  // holds the whole order, this question's own scan failure and the dialog
  // that says it included. The line keeps what it is given, so waiting
  // loses nothing.
  const mayAsk = useMayAsk("commitOffer");
  // The failure is its own question, ordered just before the offer: it is
  // said once the install and the repository effects are done with, and
  // the offer then waits for it to be dismissed.
  const maySayFailure = useMayAsk("commitOfferFailure");
  const scanFailure = useCommitOfferStore((s) => s.scanFailure);
  const scanFailureSaid = useCommitOfferStore((s) => s.scanFailureSaid);
  // The scan that would have found an offer failed instead. It is this
  // question's own failure, so it waits its turn rather than opening the
  // problems dialog over the install that started it.
  useEffect(() => {
    if (!maySayFailure || scanFailure === null) return;
    useProblemsStore.getState().showError({
      title: SCAN_FAILED_TITLE,
      message: scanFailure,
      steps: SCAN_FAILED_STEPS,
    });
    scanFailureSaid();
  }, [maySayFailure, scanFailure, scanFailureSaid]);
  if (!offer || !mayAsk) return null;
  const busy = stage.at === "busy";
  return (
    <Dialog
      open
      onOpenChange={(next) => {
        // A step is running the repository's own hooks, and closing the
        // window would not stop them.
        if (!next && !busy) leave();
      }}
    >
      <DialogContent className="max-h-[85vh] overflow-y-auto sm:max-w-xl">
        <Body offer={offer} stage={stage} />
      </DialogContent>
    </Dialog>
  );
}

function Body({ offer, stage }: { offer: ProjectOffer; stage: Stage }) {
  switch (stage.at) {
    case "offer":
    case "busy":
      return <OfferState offer={offer} stage={stage} />;
    case "commitRefused":
      return (
        <CommitRefusedState
          offer={offer}
          refused={stage.refused}
          held={stage.stillStaged}
          abandoned={stage.abandoned}
          notPutBack={stage.notPutBack}
        />
      );
    case "branchRefused":
      return <BranchRefusedState offer={offer} refused={stage.refused} />;
    case "notPutBack":
      return <NotPutBackState refused={stage.refused} />;
    case "pushRefused":
      return (
        <PushRefusedState
          refused={stage.refused}
          sha={stage.sha}
          branch={stage.branch}
          canOpen={stage.canOpen}
        />
      );
    case "pullRequestRefused":
      return (
        <PullRequestRefusedState
          offer={offer}
          refused={stage.refused}
          sha={stage.sha}
          branch={stage.branch}
        />
      );
    case "opened":
      return (
        <OpenedState
          url={stage.url}
          sha={stage.sha}
          branch={stage.branch}
          moved={stage.moved}
          before={stage.before}
          from={stage.from}
        />
      );
  }
}

function Section({
  title,
  children,
}: {
  title: string;
  children: React.ReactNode;
}) {
  return (
    <section className="space-y-1.5">
      <h3 className="text-xs font-medium uppercase tracking-wide text-muted-foreground">
        {title}
      </h3>
      {children}
    </section>
  );
}

/** Paths kendex names but does not offer to open: the shared files it
 *  writes one key in, which it leaves to the person. Printed whole — an
 *  abbreviation guesses at a directory and names a different file from the
 *  one being committed. */
function Paths({ paths }: { paths: string[] }) {
  return (
    <ul className="max-h-40 overflow-y-auto font-mono text-xs text-muted-foreground">
      {paths.map((path) => (
        <li key={path} className="break-all">
          {path}
        </li>
      ))}
    </ul>
  );
}

/** A program's own words, whole, one line at a time, in order. Nothing is
 *  summarised, reworded or truncated. A step that ran out of time has no
 *  words to show, so it says what it stopped waiting for instead. */
function Said({ refused }: { refused: Refused }) {
  if (refused.timedOut) {
    return <p className="text-sm">{didNotFinish(refused.seconds)}</p>;
  }
  return (
    <Section title={saidLabel(refused)}>
      <pre className="max-h-48 overflow-auto whitespace-pre-wrap break-all rounded bg-muted p-2 font-mono text-xs">
        {refused.said.join("\n")}
      </pre>
    </Section>
  );
}

function Row({
  label,
  children,
}: {
  label: string;
  children: React.ReactNode;
}) {
  return (
    <div className="flex items-baseline justify-between gap-3 text-sm">
      <span className="text-muted-foreground">{label}</span>
      <span className="min-w-0 break-all text-right">{children}</span>
    </div>
  );
}

function OfferState({
  offer,
  stage,
}: {
  offer: ProjectOffer;
  stage: Stage & { at: "offer" | "busy" };
}) {
  const route = useCommitOfferStore((s) => s.route);
  const message = useCommitOfferStore((s) => s.message);
  const pick = useCommitOfferStore((s) => s.pick);
  const setMessage = useCommitOfferStore((s) => s.setMessage);
  const run = useCommitOfferStore((s) => s.run);
  const leave = useCommitOfferStore((s) => s.leave);
  // A commit labelled as one action's work never carries an earlier change
  // the reader has not said yes to, so the primary action waits on that
  // answer rather than the reader finding out afterwards.
  const held = useCommitOfferStore(ready);
  const routes = routesFor(offer);
  const busy = stage.at === "busy";
  return (
    <>
      <DialogHeader>
        <DialogTitle>
          {commitOfferTitle(offer.files.length, offer.name)}
        </DialogTitle>
        <DialogDescription>{COMMIT_OFFER_STANDING}</DialogDescription>
      </DialogHeader>
      <div className="space-y-4 text-sm">
        <Section title={FILES_LABEL}>
          <ChangedFiles
            root={offer.root}
            entries={changeEntries(offer.files)}
          />
        </Section>
        <Scope offer={offer} busy={busy} />
        {offer.manifest === null ? null : (
          <Section title={MANIFEST_LEFT_LABEL}>
            <p className="text-muted-foreground">
              {manifestLeft(offer.manifest)}
            </p>
          </Section>
        )}
        {offer.shared.length > 0 ? (
          <Section title={SHARED_LABEL}>
            <Paths paths={offer.shared} />
            <p className="text-muted-foreground">{SHARED_NOTE}</p>
          </Section>
        ) : null}
        {offer.others > 0 ? (
          <Section title={OTHER_LABEL}>
            <p className="text-muted-foreground">{otherNote(offer.others)}</p>
          </Section>
        ) : null}
        <Section title={WHAT_TO_DO_LABEL}>
          <Segments routes={routes} route={route} busy={busy} pick={pick} />
          <p className="text-muted-foreground">{under(offer, route)}</p>
          {offer.push !== null ? (
            <Row label={PUSH_ROW_LABEL}>{unavailableReason(offer.push)}</Row>
          ) : null}
          {offer.pullRequest !== null ? (
            <Row label={PR_ROW_LABEL}>
              {unavailableReason(offer.pullRequest)}
            </Row>
          ) : null}
        </Section>
        <Section title={MESSAGE_LABEL}>
          <Input
            value={message}
            disabled={busy}
            onChange={(event) => setMessage(event.target.value)}
          />
        </Section>
      </div>
      <DialogFooter>
        <Button variant="outline" disabled={busy} onClick={leave}>
          {LEAVE_LABEL}
        </Button>
        <Button disabled={busy || !held} onClick={() => void run()}>
          {busy ? busyLabel(stage.step) : primaryLabel(route)}
        </Button>
      </DialogFooter>
    </>
  );
}

/** Which pending changes the commit carries.
 *
 *  Drawn only where the two choices would make different commits: with
 *  nothing else pending, "only this action" and "all pending changes" are
 *  the same commit, and a choice with one answer is a control that teaches
 *  a reader nothing.
 *
 *  Where the action touched a file that was already changed, or adds a file
 *  whose declaration was already changed, no commit can carry one change
 *  and not the other — git commits whole files. Those files are named, and
 *  the primary action is held until the reader says yes, so nothing
 *  labelled as one action's work ever quietly carries earlier work. */
function Scope({ offer, busy }: { offer: ProjectOffer; busy: boolean }) {
  const scoped = useCommitOfferStore((s) => s.scoped);
  const accepted = useCommitOfferStore((s) => s.accepted);
  const scope = useCommitOfferStore((s) => s.scope);
  const accept = useCommitOfferStore((s) => s.accept);
  const tangled = scoped === "action" ? offer.tangled : [];
  if (!offer.choice) {
    // No choice to make, and still the truth to tell: the one commit on
    // offer carries earlier work in these files.
    return offer.tangled.length > 0 ? (
      <Section title={TANGLED_LABEL}>
        <Tangles tangled={offer.tangled} />
      </Section>
    ) : null;
  }
  return (
    <Section title={WHICH_CHANGES_LABEL}>
      <div className="flex w-fit rounded-md border border-border p-0.5">
        {(["action", "all"] as Scoped[]).map((each) => (
          <button
            key={each}
            type="button"
            disabled={busy}
            onClick={() => scope(each)}
            className={cn(
              "rounded px-3 py-1 text-sm",
              each === scoped
                ? "bg-accent text-accent-foreground"
                : "text-muted-foreground hover:text-foreground",
            )}
          >
            {each === "action" ? ACTION_SEGMENT : ALL_SEGMENT}
          </button>
        ))}
      </div>
      <p className="text-muted-foreground">
        {scoped === "action"
          ? actionScopeNote(offer.actionPaths.length)
          : allScopeNote(offer.files.length)}
      </p>
      {tangled.length > 0 ? (
        <div className="space-y-2 rounded border border-border p-3">
          <Tangles tangled={tangled} />
          <Label className="flex items-baseline gap-2 text-sm font-normal">
            {/* Named on the box itself: a label element around a button is
                not what names it. */}
            <Checkbox
              aria-label={ACCEPT_EARLIER_LABEL}
              checked={accepted}
              disabled={busy}
              onCheckedChange={(next) => accept(next === true)}
            />
            <span>{ACCEPT_EARLIER_LABEL}</span>
          </Label>
          {accepted ? null : (
            <p className="text-muted-foreground">{ACCEPT_EARLIER_HELD}</p>
          )}
        </div>
      ) : null}
    </Section>
  );
}

/** Each file that cannot be committed on its own, and why. */
function Tangles({ tangled }: { tangled: TangledFile[] }) {
  return (
    <ul className="space-y-1 text-sm text-muted-foreground">
      {tangled.map((file) => (
        <li key={file.path} className="break-all">
          {file.reason === "carriesEarlier"
            ? carriesEarlier(file.path)
            : declaresWhatChanged(file.path)}
        </li>
      ))}
    </ul>
  );
}

/** The segmented control. Where every segment but `Commit` is gone it is
 *  not drawn: one segment is not a choice. */
function Segments({
  routes,
  route,
  busy,
  pick,
}: {
  routes: Route[];
  route: Route;
  busy: boolean;
  pick: (route: Route) => void;
}) {
  if (routes.length < 2) return null;
  return (
    <div className="flex w-fit rounded-md border border-border p-0.5">
      {routes.map((each) => (
        <button
          key={each}
          type="button"
          disabled={busy}
          onClick={() => pick(each)}
          className={cn(
            "rounded px-3 py-1 text-sm",
            each === route
              ? "bg-accent text-accent-foreground"
              : "text-muted-foreground hover:text-foreground",
          )}
        >
          {segmentLabel(each)}
        </button>
      ))}
    </div>
  );
}

function segmentLabel(route: Route): string {
  switch (route) {
    case "commit":
      return COMMIT_SEGMENT;
    case "push":
      return PUSH_SEGMENT;
    case "pr":
      return PR_SEGMENT;
  }
}

function primaryLabel(route: Route): string {
  switch (route) {
    case "commit":
      return COMMIT_LABEL;
    case "push":
      return PUSH_LABEL;
    case "pr":
      return PR_LABEL;
  }
}

function busyLabel(route: Route): string {
  switch (route) {
    case "commit":
      return COMMITTING_LABEL;
    case "push":
      return PUSHING_LABEL;
    case "pr":
      return OPENING_LABEL;
  }
}

/** What the picked segment does, said under the segments. */
function under(offer: ProjectOffer, route: Route): string {
  switch (route) {
    case "commit":
      return COMMIT_STAYS;
    case "push":
      return offer.openNumber !== null
        ? addsToPullRequest(offer.openNumber)
        : pushesTo(offer.remote ?? "", offer.branch);
    case "pr":
      return prMoves(offer.newBranch, offer.branch);
  }
}

function CommitRefusedState({
  offer,
  refused,
  held,
  abandoned,
  notPutBack,
}: {
  offer: ProjectOffer;
  refused: Refused;
  held: number | null;
  abandoned: boolean;
  notPutBack: Refused | null;
}) {
  const message = useCommitOfferStore((s) => s.message);
  const setMessage = useCommitOfferStore((s) => s.setMessage);
  const run = useCommitOfferStore((s) => s.run);
  const leave = useCommitOfferStore((s) => s.leave);
  return (
    <>
      <DialogHeader>
        <DialogTitle>{commitRefusedTitle(refused)}</DialogTitle>
        {abandoned ? (
          <DialogDescription>
            {backOn(offer.branch, offer.newBranch)}
          </DialogDescription>
        ) : null}
      </DialogHeader>
      <div className="space-y-4 text-sm">
        <Said refused={refused} />
        {held !== null ? <p>{stillStaged(held)}</p> : null}
        {notPutBack !== null ? (
          <>
            <p>{NOT_PUT_BACK_LINE}</p>
            <Said refused={notPutBack} />
          </>
        ) : null}
        {/* The files the commit covers stay on screen, so the person can
            still see what they are answering about. */}
        <Section title={FILES_LABEL}>
          <ChangedFiles
            root={offer.root}
            entries={changeEntries(offer.files)}
          />
        </Section>
        {offer.others > 0 ? (
          <Section title={OTHER_LABEL}>
            <p className="text-muted-foreground">{otherNote(offer.others)}</p>
          </Section>
        ) : null}
        <Section title={MESSAGE_LABEL}>
          {/* Never emptied by a refusal: the message the person settled on
              is the one they are deciding whether to change. */}
          <Input
            value={message}
            onChange={(event) => setMessage(event.target.value)}
          />
        </Section>
      </div>
      <DialogFooter>
        <Button variant="outline" onClick={leave}>
          {LEAVE_LABEL}
        </Button>
        {/* With the checkout still on the new branch, kendex stops there:
            another commit would land on the branch it could not leave. */}
        {notPutBack === null ? (
          <Button onClick={() => void run()}>{COMMIT_AGAIN_LABEL}</Button>
        ) : null}
      </DialogFooter>
    </>
  );
}

/** Nothing was left to commit on the `pr` route and the switch back then
 *  refused: no commit to report, the checkout still on the branch kendex
 *  made, and kendex stops there. */
function NotPutBackState({ refused }: { refused: Refused }) {
  const leave = useCommitOfferStore((s) => s.leave);
  return (
    <>
      <DialogHeader>
        <DialogTitle>{NOT_PUT_BACK_TITLE}</DialogTitle>
        <DialogDescription>{NOTHING_TO_COMMIT_TOAST}</DialogDescription>
      </DialogHeader>
      <div className="space-y-4 text-sm">
        <Said refused={refused} />
      </div>
      <DialogFooter>
        <Button variant="outline" onClick={leave}>
          {LEAVE_LABEL}
        </Button>
      </DialogFooter>
    </>
  );
}

/** The `pr` route's first step refused: nothing has moved, and the same
 *  offer stands without the segment that failed. */
function BranchRefusedState({
  offer,
  refused,
}: {
  offer: ProjectOffer;
  refused: Refused;
}) {
  const route = useCommitOfferStore((s) => s.route);
  const pick = useCommitOfferStore((s) => s.pick);
  const run = useCommitOfferStore((s) => s.run);
  const leave = useCommitOfferStore((s) => s.leave);
  // The store moved the picked route off `pr` when it entered this state.
  const routes = routesFor(offer).filter((each) => each !== "pr");
  return (
    <>
      <DialogHeader>
        <DialogTitle>
          {refused.timedOut
            ? commitRefusedTitle(refused)
            : BRANCH_REFUSED_TITLE}
        </DialogTitle>
      </DialogHeader>
      <div className="space-y-4 text-sm">
        <Said refused={refused} />
        <p>{BRANCH_REFUSED_LINE}</p>
        <Section title={WHAT_TO_DO_LABEL}>
          <Segments routes={routes} route={route} busy={false} pick={pick} />
          <p className="text-muted-foreground">{under(offer, route)}</p>
        </Section>
      </div>
      <DialogFooter>
        <Button variant="outline" onClick={leave}>
          {LEAVE_LABEL}
        </Button>
        <Button onClick={() => void run()}>{primaryLabel(route)}</Button>
      </DialogFooter>
    </>
  );
}

function PushRefusedState({
  refused,
  sha,
  branch,
  canOpen,
}: {
  refused: Refused;
  sha: string;
  branch: string;
  canOpen: boolean;
}) {
  const leave = useCommitOfferStore((s) => s.leave);
  const openPullRequest = useCommitOfferStore((s) => s.openPullRequest);
  return (
    <>
      <DialogHeader>
        <DialogTitle>{pushRefusedTitle(refused)}</DialogTitle>
      </DialogHeader>
      <div className="space-y-4 text-sm">
        <Row label={COMMIT_ROW_LABEL}>{commitOn(sha, branch)}</Row>
        <Said refused={refused} />
        <p>{commitIsOn(branch)}</p>
      </div>
      <DialogFooter>
        <Button variant="outline" onClick={leave}>
          {LEAVE_IT_HERE_LABEL}
        </Button>
        {canOpen ? (
          <Button onClick={() => void openPullRequest()}>
            {OPEN_PR_LABEL}
          </Button>
        ) : null}
      </DialogFooter>
    </>
  );
}

function PullRequestRefusedState({
  offer,
  refused,
  sha,
  branch,
}: {
  offer: ProjectOffer;
  refused: Refused;
  sha: string;
  branch: string;
}) {
  const leave = useCommitOfferStore((s) => s.leave);
  const remote = offer.remote ?? "";
  return (
    <>
      <DialogHeader>
        <DialogTitle>{pullRequestRefusedTitle(refused)}</DialogTitle>
      </DialogHeader>
      <div className="space-y-4 text-sm">
        <Row label={COMMIT_ROW_LABEL}>{commitOn(sha, branch)}</Row>
        <Row label={BRANCH_ROW_LABEL}>{remoteBranch(remote, branch)}</Row>
        <Said refused={refused} />
        <p>{branchIsOn(remote)}</p>
      </div>
      <DialogFooter>
        <Button onClick={leave}>{DONE_LABEL}</Button>
      </DialogFooter>
    </>
  );
}

function OpenedState({
  url,
  sha,
  branch,
  moved,
  before,
  from,
}: {
  url: string;
  sha: string;
  branch: string;
  moved: boolean;
  before: string | null;
  from: string;
}) {
  const leave = useCommitOfferStore((s) => s.leave);
  return (
    <>
      <DialogHeader>
        <DialogTitle>{PR_OPEN_TITLE}</DialogTitle>
      </DialogHeader>
      <div className="space-y-4 text-sm">
        <Row label={COMMIT_ROW_LABEL}>{commitOn(sha, branch)}</Row>
        <Row label={PR_ROW_LABEL}>
          <ExternalLink url={url}>{url}</ExternalLink>
        </Row>
        {moved ? <p>{nowOn(branch)}</p> : <p>{stillCarries(from)}</p>}
        {/* kendex never moves a branch ref backwards, so the way to put it
            back is printed rather than run. */}
        {!moved && before !== null ? (
          <Row label={putBackRowLabel(from)}>
            <Copyable text={resetCommand(before)} />
          </Row>
        ) : null}
      </div>
      <DialogFooter>
        <Button onClick={leave}>{DONE_LABEL}</Button>
      </DialogFooter>
    </>
  );
}

/** A command the person runs themselves, beside a button that copies it.
 *  Nothing here runs it. */
function Copyable({ text }: { text: string }) {
  const [copied, setCopied] = useState(false);
  return (
    <span className="inline-flex items-center gap-2">
      <code className="font-mono text-xs">{text}</code>
      <Button
        variant="ghost"
        size="icon-sm"
        aria-label={`Copy ${text}`}
        onClick={() => {
          void navigator.clipboard.writeText(text).then(() => {
            setCopied(true);
            window.setTimeout(() => setCopied(false), 1500);
          });
        }}
      >
        {copied ? (
          <CheckIcon className="size-3.5" />
        ) : (
          <CopyIcon className="size-3.5" />
        )}
      </Button>
    </span>
  );
}
