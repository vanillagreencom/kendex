import { useEffect } from "react";
import { toast } from "sonner";
import { create } from "zustand";
import { type AuditView, commands } from "@/bindings";
import {
  invalidations,
  READ_PENDING,
  type ReadState,
  readOf,
} from "@/lib/read-state";
import { settled } from "@/lib/settled";
import { auditRunner, type ItemActions, itemActions } from "./audit-items";

interface AuditState extends ItemActions {
  views: AuditView[];
  auditing: boolean;
  /** Why the last item action failed, or null. */
  error: string | null;
  /** How the last audit itself went. Kept apart from `error` above, which
   *  item actions also write, so a failed remove or adopt never reads as a
   *  machine that could not be checked. */
  read: ReadState;
  busy: boolean;
  /** The startup audit has already toasted its failure — suppresses repeat
   * toasts on every silent retry until one succeeds. */
  backgroundFailureAnnounced: boolean;
  /** Unix ms of the last audit that answered, null until one has. What a
   *  reading on screen is dated by. */
  auditedAt: number | null;
  refresh: (opts?: { force?: boolean }) => Promise<void>;
}

/** How long an audit answers for before a visit pays for a fresh one. */
const AUDIT_FRESH_FOR_MS = 60_000;

export const useAuditStore = create<AuditState>((set, get) => {
  // The rule, in the one place that can hold it: a reading is kept only
  // when no command attempt started or ended while it ran. Reading every
  // scope takes seconds, a command writes throughout its own run, and it
  // may have written whatever it went on to answer. No item action forces
  // an audit of its own — the runner refreshes the scan alone — so nothing
  // else would correct a reading that put an adopted or removed row back.
  const attempts = invalidations();
  const run = auditRunner(set, get, attempts.moved);

  // The audit in flight, and the one forced request waiting behind it.
  // These are the truth about what is running, not the `auditing` flag: the
  // flag says what to draw, and a request that arrives mid-run has to know
  // whether there is something real to wait for.
  let inFlight: Promise<void> | null = null;
  let queued: Promise<void> | null = null;

  const audit = async (): Promise<void> => {
    const asked = attempts.since();
    set({ auditing: true });
    try {
      // `settled` lands a rejected call as the same failed audit as a
      // returned refusal, which keeps Home's attention section off its
      // skeleton, the same as the scan.
      const response = await settled(commands.auditAll());
      // Answered for a moment before something the reader did, so it
      // answers for nothing now — this read's own failure arm included,
      // since a read that did not finish is not news about the state it
      // left behind. The stamp goes with it: a command installs its own
      // scope and nothing re-reads the rest, so a stamp left standing would
      // hold the freshness window open over a machine this cannot speak
      // for, and every later unforced visit would reuse it.
      if (attempts.stale(asked)) {
        set({ auditedAt: null });
        return;
      }
      if (response.status === "ok") {
        set({
          views: response.data,
          auditedAt: Date.now(),
          read: readOf(response),
          error: null,
          backgroundFailureAnnounced: false,
        });
      } else {
        set({ error: response.error, read: readOf(response) });
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
    auditing: false,
    error: null,
    read: READ_PENDING,
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
