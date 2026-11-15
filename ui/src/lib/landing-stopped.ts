import type { ItemWarning, LandingStopped } from "@/bindings";

/** How a write that lands in two steps stopped, as the window acts on it.
 *  `unknown` is the call failing on its way — the transport fold
 *  `typedError` answers with a bare string, or a phase this UI does not know
 *  from a binary older or newer than it. The write may have run, so it is
 *  neither a refusal, which the person may answer by asking again, nor a
 *  recorded landing, which says what landed. */
export type LandingStop =
  | { phase: "refused"; message: string }
  | { phase: "recorded"; message: string; written: ItemWarning[] | undefined }
  | { phase: "unknown"; message: string };

/** The one reader of [LandingStopped] for every command that answers it. */
export function landingStop(failure: LandingStopped | string): LandingStop {
  if (typeof failure === "string")
    return { phase: "unknown", message: failure };
  switch (failure.phase) {
    case "refused":
      return { phase: "refused", message: failure.message };
    case "recorded":
      return {
        phase: "recorded",
        message: failure.message,
        written: failure.written,
      };
    default: {
      const unread: never = failure;
      return { phase: "unknown", message: JSON.stringify(unread) };
    }
  }
}
