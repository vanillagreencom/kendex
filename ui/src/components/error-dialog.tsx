import { type ReactNode, useRef } from "react";
import { CLASS_TONES } from "@/components/home/attention-rows";
import { STATUS_TONES } from "@/components/status-note";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { SEVERAL_FAILURES_TITLE } from "@/lib/copy";
import {
  type ErrorAction,
  type Failure,
  useProblemsStore,
} from "@/stores/problems";

/** The one modal for a failed user action, rendered once in App.tsx —
 *  every store's failure path calls showError instead of owning dialog
 *  markup of its own.
 *
 *  One failure is the dialog's title, with its controls in the footer.
 *  Several each stand under their own title, with their controls beneath
 *  them: a footer of two Retry buttons could not say which one retries
 *  what. The failures scroll between a title and a footer that stay put,
 *  so however many joined, every one and OK stay within the window. */
export function ErrorDialog() {
  const dialog = useProblemsStore((s) => s.dialog);
  const closeError = useProblemsStore((s) => s.closeError);
  const several = dialog.joined.length > 0;
  const title = several ? SEVERAL_FAILURES_TITLE : dialog.title;
  // Focus opens on OK, in the footer: a control among the failures would
  // scroll them to itself and hide the first ones as the dialog opens.
  const ok = useRef<HTMLButtonElement>(null);
  const act = (action: ErrorAction) => {
    closeError();
    action.onClick();
  };

  return (
    <Dialog
      open={dialog.open}
      onOpenChange={(next) => {
        if (!next) closeError();
      }}
    >
      <DialogContent initialFocus={ok} className="flex max-h-[85vh] flex-col">
        <DialogHeader>
          <DialogTitle className={STATUS_TONES[CLASS_TONES.failed].text}>
            {title}
          </DialogTitle>
        </DialogHeader>
        {several || dialog.message || dialog.steps.length > 0 ? (
          <FailureList title={title}>
            {several ? (
              [dialog, ...dialog.joined].map((failure, index) => (
                // A dialog's failures only ever append, so a position names one.
                // biome-ignore lint/suspicious/noArrayIndexKey: append-only list
                <section key={index} className="flex min-w-0 flex-col gap-2">
                  <h3 className="text-sm font-medium break-words">
                    {failure.title}
                  </h3>
                  <FailureBody failure={failure} />
                  {failure.actions.length > 0 ? (
                    <div className="flex flex-wrap gap-2">
                      {failure.actions.map((action) => (
                        <Button
                          key={action.label}
                          variant="outline"
                          size="sm"
                          onClick={() => act(action)}
                        >
                          {action.label}
                        </Button>
                      ))}
                    </div>
                  ) : null}
                </section>
              ))
            ) : (
              <FailureBody failure={dialog} />
            )}
          </FailureList>
        ) : null}
        <DialogFooter>
          {several
            ? null
            : dialog.actions.map((action) => (
                <Button
                  key={action.label}
                  variant="outline"
                  onClick={() => act(action)}
                >
                  {action.label}
                </Button>
              ))}
          <Button ref={ok} onClick={closeError}>
            OK
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

/** The part of the dialog that scrolls: every failure, between a title and
 *  a footer that stay put. */
function FailureList({
  title,
  children,
}: {
  title: string;
  children: ReactNode;
}) {
  return (
    <>
      {/* biome-ignore-start lint/a11y/noNoninteractiveTabindex: a failure
          with no control of its own has nothing to Tab to, and WKWebView
          and WebKitGTK do not focus an overflowing container by
          themselves, so without this stop a keyboard could not scroll to
          it. WCAG's scrollable-region-focusable rule asks for it. */}
      <section
        tabIndex={0}
        aria-label={title}
        className="flex min-h-0 min-w-0 flex-col gap-4 overflow-y-auto outline-none focus-visible:ring-[3px] focus-visible:ring-ring/50"
      >
        {children}
      </section>
      {/* biome-ignore-end lint/a11y/noNoninteractiveTabindex: the rule
          stands for everything else here. */}
    </>
  );
}

/** A failure's error and what to do about it, under whatever titles it. */
function FailureBody({ failure }: { failure: Failure }) {
  return (
    <>
      {failure.message ? (
        <p className="break-words rounded-md bg-muted/50 p-2 font-mono text-xs text-muted-foreground">
          {failure.message}
        </p>
      ) : null}
      {failure.steps.length > 0 ? (
        <ul className="list-disc space-y-1 pl-5 text-sm text-muted-foreground">
          {failure.steps.map((step) => (
            <li key={step}>{step}</li>
          ))}
        </ul>
      ) : null}
    </>
  );
}
