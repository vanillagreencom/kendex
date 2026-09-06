import { useEffect } from "react";
import { LEGAL } from "@/bindings";
import { ExternalLink } from "@/components/external-link";
import { Button } from "@/components/ui/button";
import { WindowControls } from "@/components/window-controls";
import { useTermsStore } from "@/stores/terms";

/**
 * The first-run screen: what kendex asks a person to accept before it puts
 * anything on screen, and the one control that records the answer.
 *
 * It is the whole of the accept step. Nothing else in the app waits on the
 * record — no page, install or apply refuses because it is missing — so
 * this screen is the only place the question is ever in the way.
 *
 * One button, saying what it does. A "Continue" that quietly counted as
 * agreement, or a box already ticked, would be a person carried past a
 * document they never chose to accept.
 */
export function TermsGate() {
  const state = useTermsStore((s) => s.state);
  const error = useTermsStore((s) => s.error);
  const accept = useTermsStore((s) => s.accept);
  const load = useTermsStore((s) => s.load);

  useEffect(() => {
    void load();
  }, [load]);

  if (state?.ask !== true) return null;

  return (
    <div
      role="dialog"
      aria-modal="true"
      aria-label="Terms of Service and Privacy Policy"
      className="fixed inset-0 z-40 flex items-center justify-center bg-background"
    >
      {/* The window still minimizes, resizes and closes while this is up:
          a screen that asks a question must not also be the one thing
          standing between a person and closing the app. */}
      <div data-tauri-drag-region className="absolute inset-x-0 top-0 h-8" />
      <WindowControls className="absolute top-0 right-0 z-50" />
      <div className="mx-auto flex w-full max-w-lg flex-col gap-5 px-8">
        <h1 className="text-lg font-medium">Before you start</h1>
        <div className="flex flex-col gap-3 text-sm text-muted-foreground">
          <p>
            kendex installs agents, skills, hooks and other packages written by
            other people. Your AI coding tools load and run them with the access
            those tools have. Checking a package before you install it is yours
            to do, and kendex is not liable for data a package loses, corrupts
            or changes.
          </p>
          <p>
            The app and the command line collect nothing about you or your code.
            What kendex.ai stores is in the privacy policy.
          </p>
          <p className="flex gap-4">
            <ExternalLink url={LEGAL.termsUrl}>Terms of Service</ExternalLink>
            <ExternalLink url={LEGAL.privacyUrl}>Privacy Policy</ExternalLink>
          </p>
        </div>
        <div className="flex flex-col gap-2">
          <Button className="self-start" onClick={() => void accept()}>
            I agree to the Terms and Privacy Policy
          </Button>
          {error === null ? null : (
            <span className="text-critical text-sm" role="alert">
              {error}
            </span>
          )}
        </div>
      </div>
    </div>
  );
}
