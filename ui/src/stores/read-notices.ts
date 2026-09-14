import { create } from "zustand";

const STORAGE_KEY = "kendex:read-notices";

/** A notice's slot and what it said when it was read. A slot read at one
 *  identity is unread again at any other, so a changed notice reaches the
 *  person again without anything clearing the old answer. */
export interface ReadKey {
  id: string;
  identity: string;
}

/** Each slot's identity when last read. */
export type ReadNotices = Record<string, string>;

/** Storage that is blocked, cleared or unparseable reads as nothing read:
 *  a notice shown twice costs a click, one hidden unseen costs the news. */
function load(): ReadNotices {
  try {
    const parsed: unknown = JSON.parse(
      localStorage.getItem(STORAGE_KEY) ?? "{}",
    );
    return parsed !== null &&
      typeof parsed === "object" &&
      !Array.isArray(parsed)
      ? (parsed as ReadNotices)
      : {};
  } catch {
    return {};
  }
}

interface ReadNoticesState {
  read: ReadNotices;
  markRead: (key: ReadKey) => void;
}

/** Which Notice and Update rows a person has dismissed or seen, kept in
 *  this browser's storage. Problems and Decisions never reach it: they
 *  stand until the reads behind them change. */
export const useReadNotices = create<ReadNoticesState>((set, get) => ({
  read: load(),
  markRead: ({ id, identity }) => {
    if (get().read[id] === identity) return;
    const read = { ...get().read, [id]: identity };
    set({ read });
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify(read));
    } catch {
      // Storage refused the write: the dismissal holds for this session and
      // the notice is unread again after a reload, which is the safe side.
    }
  },
}));

export const isRead = (read: ReadNotices, key: ReadKey): boolean =>
  read[key.id] === key.identity;
