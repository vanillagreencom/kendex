import { useEffect } from "react";
import { toast } from "sonner";
import { create } from "zustand";
import { type AuditView, commands } from "@/bindings";
import { settled } from "@/lib/settled";
import { keepUnreadable, stampClean } from "./audit-fold";
import { auditRunner, type ItemActions, itemActions } from "./audit-items";

interface AuditState extends ItemActions {
  views: AuditView[];
  auditing: boolean;
  error: string | null;
  /** Why the last audit itself failed, or null — written only by
   *  `refresh`. The shared `error` above is also set by item actions, so a
   *  failed remove or adopt would otherwise read as a machine that could
   *  not be checked. */
  checkError: string | null;
  busy: boolean;
  /** The startup audit has already toasted its failure — suppresses repeat
   * toasts on every silent retry until one succeeds. */
  backgroundFailureAnnounced: boolean;
  /** Unix ms of the last audit that came back clean; null until one has. */
  auditedAt: number | null;
  /** When each scope's reading on screen was taken, keyed by scope. A scope
   *  the audit could not read keeps its old entry: what is on screen for it
   *  is that old, whatever the machine-wide audit did a moment ago. */
  scopeCheckedAt: Record<string, number>;
  refresh: (opts?: { force?: boolean }) => Promise<void>;
}

/** How long an audit answers for before a visit pays for a fresh one. */
const AUDIT_FRESH_FOR_MS = 60_000;

export const useAuditStore = create<AuditState>((set, get) => {
  // Bumped whenever something newer than a running audit is installed. An
  // audit reads every scope on the machine over seconds; a command that
  // lands while one is in flight read its scope later than the audit did,
  // so a response stamped before it must not be written over the top. Left
  // unguarded, a row the person had just settled came back — dated fresh,
  // and so kept for the whole freshness window, with a retry failing
  // against work core had already done.
  let generation = 0;
  const run = auditRunner(set, get, () => {
    generation += 1;
  });

  // The audit in flight, and the one forced request waiting behind it.
  // These are the truth about what is running, not the `auditing` flag: the
  // flag says what to draw, and a request that arrives mid-run has to know
  // whether there is something real to wait for.
  let inFlight: Promise<void> | null = null;
  let queued: Promise<void> | null = null;

  const audit = async (): Promise<void> => {
    const asked = generation;
    set({ auditing: true });
    try {
      // `settled` lands a rejected call as the same failed audit as a
      // returned refusal, which keeps Home's attention section off its
      // skeleton, the same as the scan.
      const response = await settled(commands.auditAll());
      // Answered for a moment before something the reader did, so it
      // answers for nothing now — the failure arm included, since a read
      // that did not finish is not news about the state it left behind.
      // `auditedAt` stays where it was, so the next visit pays for a read
      // that can speak.
      if (generation !== asked) return;
      if (response.status === "ok") {
        const now = Date.now();
        set({
          views: keepUnreadable(get().views, response.data),
          scopeCheckedAt: stampClean(get().scopeCheckedAt, response.data, now),
          auditedAt: now,
          error: null,
          checkError: null,
          backgroundFailureAnnounced: false,
        });
      } else {
        set({ error: response.error, checkError: response.error });
        if (!get().backgroundFailureAnnounced) {
          toast.error(response.error);
          set({ backgroundFailureAnnounced: true });
        }
      }
    } finally {
      set({ auditing: false });
    }
  };

  const start = (): Promise<void> => {
    const running = audit().finally(() => {
      if (inFlight === running) inFlight = null;
    });
    inFlight = running;
    return running;
  };

  return {
    views: [],
    auditedAt: null,
    scopeCheckedAt: {},
    auditing: false,
    error: null,
    checkError: null,
    busy: false,
    backgroundFailureAnnounced: false,

    // Auditing the whole machine is seconds of work to answer a question
    // already on screen, so a recent answer is reused. A forced request is
    // the opposite claim — the bytes changed — and is never reused away:
    // every path that writes what is scored forces, and so does the person
    // who pressed Scan again.
    refresh: (opts) => {
      const force = opts?.force === true;
      if (inFlight) {
        // The running audit may already have read the files this force is
        // about, so it cannot answer for them. Dropping the force left
        // every score on screen quoting the state before whatever prompted
        // it. Exactly one follow-up waits: a second force joins that one
        // rather than stacking a queue of identical machine-wide reads.
        if (!force) return inFlight;
        queued ??= inFlight.then(() => {
          queued = null;
          return start();
        });
        return queued;
      }
      const auditedAt = get().auditedAt;
      const fresh =
        auditedAt != null && Date.now() - auditedAt < AUDIT_FRESH_FOR_MS;
      if (fresh && !force) return Promise.resolve();
      return start();
    },

    ...itemActions(run),
  };
});

/** Ask for a fresh audit as a page that renders one comes up.
 *
 *  Content can change under the app between visits — an editor saved a
 *  skill, another tool wrote a hook — and a page showing a score is showing
 *  a claim about files it has not looked at since. The store's own
 *  freshness window decides whether the ask costs anything, so a page says
 *  what it needs without knowing when the last audit ran. */
export function useAuditOnMount() {
  const refresh = useAuditStore((s) => s.refresh);
  useEffect(() => {
    void refresh();
  }, [refresh]);
}
