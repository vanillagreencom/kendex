import { toast } from "sonner";
import { create } from "zustand";
import { commands, type ScanResult } from "@/bindings";
import { settled } from "@/lib/settled";

interface ScanState {
  result: ScanResult | null;
  scanning: boolean;
  error: string | null;
  /** When the last successful scan finished, for the status footer's
   * "scanned Nm ago" — null until the first scan completes. */
  lastScanAt: number | null;
  /** A background scan (startup, focus) has already toasted its failure —
   * suppresses repeat toasts on every silent retry until one succeeds. A
   * press of "Scan again" re-opens it, so its window is said once. */
  backgroundFailureAnnounced: boolean;
  refresh: (opts?: { announce?: boolean }) => Promise<void>;
}

export const useScanStore = create<ScanState>((set, get) => {
  // The scan in flight, and the one re-read waiting behind it. These are the
  // truth about what is running, not the `scanning` flag: the flag says what
  // to draw, and a request arriving mid-scan has to know whether there is
  // something real to wait for. The audit store keeps the same pair for the
  // same reason.
  let inFlight: Promise<void> | null = null;
  let queued: Promise<void> | null = null;

  const scan = async (opts?: { announce?: boolean }): Promise<void> => {
    set({ scanning: true });
    // The flag comes down however the call ends: a rejected call that left
    // it up would skip every later scan for the session.
    try {
      // `settled` lands a rejected call as the same failed scan as a
      // returned refusal, which keeps Home off its skeletons. The last
      // good result stays kept either way.
      const response = await settled(commands.scanMachine());
      if (response.status === "ok") {
        set({
          result: response.data,
          error: null,
          lastScanAt: Date.now(),
          backgroundFailureAnnounced: false,
        });
      } else {
        set({ error: response.error });
        if (opts?.announce || !get().backgroundFailureAnnounced) {
          toast.error(response.error);
          set({ backgroundFailureAnnounced: true });
        }
      }
    } finally {
      set({ scanning: false });
    }
  };

  const start = (opts?: { announce?: boolean }): Promise<void> => {
    const running = scan(opts).finally(() => {
      if (inFlight === running) inFlight = null;
    });
    inFlight = running;
    return running;
  };

  return {
    result: null,
    scanning: false,
    error: null,
    lastScanAt: null,
    backgroundFailureAnnounced: false,

    // A scan already out cannot answer for what has happened since it began
    // reading — which is the whole of what a write behind it needs read. So
    // an overlapping request is not dropped, as it was: it waits on the one
    // running and takes a re-read behind it. Exactly one waits, a second
    // arrival joining that one rather than stacking identical whole-machine
    // reads.
    refresh: (opts) => {
      if (!inFlight) return start(opts);
      // A joining caller gets the slot's opts, not its own, so re-arm the
      // flag the toast runs on: a press cannot join a read into silence.
      if (opts?.announce) set({ backgroundFailureAnnounced: false });
      queued ??= inFlight.then(() => {
        queued = null;
        return start(opts);
      });
      return queued;
    },
  };
});
