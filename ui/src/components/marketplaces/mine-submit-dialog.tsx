import { Check, CircleHelp, X } from "lucide-react";
import { useEffect, useState } from "react";
import { commands, type SubmitPreflight } from "@/bindings";
import { DotSpinner } from "@/components/loading";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { isShapedRefusal, refusalWords } from "@/lib/refusal";
import { hasCredential, useAccountStore } from "@/stores/account";

/** The preflight checklist and the submit itself. The server has the last
 * word — push authority and visibility are its verdicts, and its refusal
 * sentence shows here verbatim. */
export function MineSubmitDialog({
  path,
  open,
  onOpenChange,
  onSubmitted,
}: {
  path: string;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onSubmitted: () => void;
}) {
  const signedIn = useAccountStore((s) => hasCredential(s.account));
  const signingIn = useAccountStore((s) => s.signingIn);
  const userCode = useAccountStore((s) => s.userCode);
  const signIn = useAccountStore((s) => s.signIn);
  const cancelSignIn = useAccountStore((s) => s.cancelSignIn);
  const accountError = useAccountStore((s) => s.error);
  // A read that failed is why the account is unknown, and unknown is what
  // this dialog offers a sign-in for. Without it the offer has no reason
  // on screen and points at a server that is already out of reach.
  const readError = useAccountStore((s) => s.readError);
  const refused = useAccountStore((s) => s.refused);
  const handovers = useAccountStore((s) => s.handovers);
  const [preflight, setPreflight] = useState<SubmitPreflight | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [submitted, setSubmitted] = useState<string | null>(null);

  useEffect(() => {
    if (!open) {
      setPreflight(null);
      setError(null);
      setSubmitted(null);
      cancelSignIn();
      return;
    }
    void commands.mineSubmitPreflight(path).then((answer) => {
      if (answer.status === "ok") setPreflight(answer.data);
      else setError(answer.error);
    });
  }, [open, path, cancelSignIn]);

  const submit = () => {
    if (!preflight?.candidate) return;
    setBusy(true);
    setError(null);
    // The account this submit goes out under. What comes back is read
    // against it, so an expiry that lands after the sign-in was replaced
    // cannot end the account that replaced it.
    const since = handovers();
    void commands.mineSubmit(preflight.candidate).then((answer) => {
      setBusy(false);
      if (answer.status === "error") {
        // The refusal answers the submit this person pressed, so it is
        // shown either way. Whether it is also news about the account is
        // the store's to decide.
        setError(refusalWords(answer.error));
        // An expired sign-in takes the offer away with it: the footer
        // reads the account, so this dialog stops offering a submit
        // nothing can carry and offers the sign-in that fixes it. A
        // transport failure is news about the channel, not the credential,
        // so it never reaches that decision.
        if (isShapedRefusal(answer.error)) refused(answer.error, since);
        return;
      }
      setSubmitted(answer.data.status);
      onSubmitted();
    });
  };

  const openOnSite = () => {
    void commands.openUrl("https://kendex.ai/submit");
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Submit to the community</DialogTitle>
          <DialogDescription>
            kendex.ai verifies you can push to the repository, indexes it, and
            lists it for everyone to subscribe to.
          </DialogDescription>
        </DialogHeader>
        {submitted ? (
          <p className="text-sm">
            Submitted.{" "}
            {submitted === "listed"
              ? "It is live in the community directory."
              : "It is in the review queue — the row will say when it is listed."}
          </p>
        ) : preflight === null && error === null ? (
          <p className="flex items-center gap-2 text-sm text-muted-foreground">
            <DotSpinner /> Checking this folder…
          </p>
        ) : preflight ? (
          <ul className="space-y-1.5 text-sm">
            {preflight.checks.map((row) => (
              <li key={row.label} className="flex items-start gap-2">
                {row.ok === true ? (
                  <Check className="mt-0.5 size-4 shrink-0 text-ok" />
                ) : row.ok === false ? (
                  <X className="mt-0.5 size-4 shrink-0 text-critical" />
                ) : (
                  <CircleHelp className="mt-0.5 size-4 shrink-0 text-muted-foreground" />
                )}
                <span>
                  {row.label}
                  {row.fix ? (
                    <span className="block text-xs text-muted-foreground">
                      {row.fix}
                    </span>
                  ) : null}
                </span>
              </li>
            ))}
          </ul>
        ) : null}
        {signingIn && userCode ? (
          <p className="text-sm text-muted-foreground">
            A kendex.ai page just opened with the code{" "}
            <span className="font-mono font-medium">{userCode}</span> — approve
            it there and this dialog finishes on its own.
          </p>
        ) : null}
        {(error ?? accountError ?? readError) ? (
          <p className="text-sm text-critical" role="alert">
            {error ?? accountError ?? readError}
          </p>
        ) : null}
        <DialogFooter>
          <Button variant="ghost" onClick={openOnSite}>
            Open kendex.ai/submit
          </Button>
          <Button variant="outline" onClick={() => onOpenChange(false)}>
            {submitted ? "Done" : "Cancel"}
          </Button>
          {submitted ? null : signedIn ? (
            <Button
              onClick={submit}
              disabled={busy || !preflight?.candidate || !preflight.ready}
            >
              {busy ? "Submitting…" : "Submit"}
            </Button>
          ) : (
            <Button
              onClick={() => {
                // The refusal that offered this sign-in has been acted
                // on, and the alert now belongs to the sign-in. Left
                // standing it would outlive its own remedy and cover
                // whatever the device flow has to say for itself.
                setError(null);
                void signIn();
              }}
              disabled={signingIn}
            >
              {signingIn ? "Waiting for approval…" : "Sign in with GitHub"}
            </Button>
          )}
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
