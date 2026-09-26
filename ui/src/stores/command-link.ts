import { toast } from "sonner";
import { create } from "zustand";
import { type CommandLink, type CommandLinkState, commands } from "@/bindings";
import { answerNotRecorded } from "@/lib/copy-command-link";
import { readOrder } from "@/lib/read-state";
import { isShapedRefusal } from "@/lib/refusal";
import { settled } from "@/lib/settled";

type Offered = Extract<CommandLink, { kind: "offered" }>;

/** Where the last install attempt stands. One value, so the dialog and the
 *  Settings row draw the same moment. */
export type Stage =
  | { at: "idle" }
  | { at: "working" }
  | { at: "done" }
  | { at: "cancelled" }
  /** What is at the link now took no install; `command` says what. */
  | { at: "refused"; command: CommandLink }
  | { at: "failed"; message: string };

interface CommandLinkStore {
  /** Null until the first read lands, and after a read that failed: the
   *  question is never put, and the row never drawn, on a state nobody
   *  read. */
  state: CommandLinkState | null;
  /** Why the read failed, for the Settings row. */
  readError: string | null;
  stage: Stage;
  /** The offer the first-launch question is on screen about, from the read
   *  that said to ask until the question is answered. Held apart from
   *  `state`, which an install replaces with an answer that no longer asks
   *  while the dialog still has to say how the install went. */
  question: Offered | null;
  /** The question was answered in this window. The record normally says
   *  so too; this covers a record that could not be written. */
  answered: boolean;
  load: () => Promise<void>;
  install: () => Promise<void>;
  /** Close the first-launch question and record that it was answered. */
  answer: () => Promise<void>;
}

/**
 * The kendex command the macOS app carries, and the one link that puts it
 * on `PATH`.
 *
 * Whether to ask, what to offer, and what an install may replace are all
 * `kendex_core::command_link`'s answers; this holds them and the stage of
 * the attempt in flight.
 */
const order = readOrder();

export const useCommandLinkStore = create<CommandLinkStore>((set, get) => ({
  state: null,
  readError: null,
  stage: { at: "idle" },
  question: null,
  answered: false,

  load: async () => {
    const ticket = order.begin();
    const read = await settled(commands.commandLinkState());
    // The dialog, Settings and window focus each read this; an older
    // answer landing after a newer one would put a stale state back.
    if (!order.lands(ticket)) return;
    if (read.status !== "ok") {
      set({ state: null, readError: read.error });
      return;
    }
    // A cancelled or failed attempt is news until the page is read again;
    // an open question keeps its own ending on screen.
    const { stage, question } = get();
    const resting = stage.at !== "working" && question === null;
    set({
      state: read.data,
      readError: null,
      ...(resting ? { stage: { at: "idle" } as const } : {}),
    });
    const { command, ask } = read.data;
    if (ask && command.kind === "offered" && !get().answered) {
      if (get().question === null) set({ question: command });
    } else if (get().stage.at === "idle") {
      // A command installed while the question waited leaves nothing to ask.
      set({ question: null });
    }
  },

  // An install or answer lands a newer state than any read still in flight,
  // so each takes a ticket that read cannot outrank.
  install: async () => {
    if (get().stage.at === "working") return;
    set({ stage: { at: "working" } });
    const run = await settled(commands.commandLinkInstall());
    if (run.status === "ok") {
      order.begin();
      set({ state: run.data, stage: { at: "done" } });
      return;
    }
    const refusal = run.error;
    if (!isShapedRefusal(refusal)) {
      set({ stage: { at: "failed", message: refusal } });
      return;
    }
    switch (refusal.kind) {
      case "cancelled":
        set({ stage: { at: "cancelled" } });
        return;
      case "notOffered":
        set({ stage: { at: "refused", command: refusal.command } });
        // The row redraws from what is there now rather than from what
        // was offered when it was drawn.
        await get().load();
        return;
      case "failed":
        set({ stage: { at: "failed", message: refusal.message } });
        return;
      default: {
        const unreachable: never = refusal;
        return unreachable;
      }
    }
  },

  answer: async () => {
    set({ question: null, answered: true, stage: { at: "idle" } });
    const recorded = await settled(commands.commandLinkPromptAnswered());
    if (recorded.status === "ok") {
      order.begin();
      set({ state: recorded.data });
    } else toast.error(answerNotRecorded(recorded.error));
  },
}));
