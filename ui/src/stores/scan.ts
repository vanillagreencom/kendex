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
   * user clicking "Scan again" always hears about it regardless. */
  backgroundFailureAnnounced: boolean;
  refresh: (opts?: { announce?: boolean }) => Promise<void>;
}

export const useScanStore = create<ScanState>((set, get) => ({
  result: null,
  scanning: false,
  error: null,
  lastScanAt: null,
  backgroundFailureAnnounced: false,
  refresh: async (opts) => {
    if (get().scanning) return;
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
  },
}));
