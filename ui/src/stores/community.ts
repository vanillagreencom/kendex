// The Community tab's state: the kendex.ai directory (served from the
// app's on-disk cache, honest about staleness) and skills.sh search plus
// its proxied leaderboard.
import { create } from "zustand";
import { commands, type DirectoryView, type SkillsShHit } from "@/bindings";
import { readOrder } from "@/lib/read-state";

export type SkillsShMode = "search" | "all-time" | "trending" | "hot";

interface CommunityState {
  directory: DirectoryView | null;
  loading: boolean;
  /** Set only when there is nothing to show at all — a stale list renders
   * with its "as of" line instead. */
  error: string | null;

  skillsshAvailable: boolean;
  skillsshHits: SkillsShHit[] | null;
  skillsshMode: SkillsShMode;
  /** The leaderboard needs the kendex.ai proxy; when it is not there the
   * chips hide and search carries the whole sub-tab. */
  skillsshChips: boolean;
  skillsshSearching: boolean;
  skillsshError: string | null;

  load: (refresh: boolean) => Promise<void>;
  searchSkillssh: (query: string) => Promise<void>;
  loadLeaderboard: (view: Exclude<SkillsShMode, "search">) => Promise<void>;
}

/** Stale results never land on a newer query: the search box asks on every
 *  keystroke and a chip asks beside it, so several are routinely out. */
const order = readOrder();

export const useCommunityStore = create<CommunityState>((set) => ({
  directory: null,
  loading: false,
  error: null,
  skillsshAvailable: true,
  skillsshHits: null,
  skillsshMode: "search",
  skillsshChips: true,
  skillsshSearching: false,
  skillsshError: null,

  load: async (refresh) => {
    set({ loading: true });
    try {
      const [view, available] = await Promise.all([
        commands.communityDirectory(refresh),
        commands.communitySkillsshAvailable(),
      ]);
      if (view.status === "ok") {
        set({ directory: view.data, error: null });
      } else {
        set({ error: view.error });
      }
      set({
        skillsshAvailable: available.status === "ok" ? available.data : false,
      });
    } finally {
      set({ loading: false });
    }
  },

  searchSkillssh: async (query) => {
    const ticket = order.begin();
    if (!query.trim()) {
      set({
        skillsshHits: null,
        skillsshError: null,
        skillsshSearching: false,
        skillsshMode: "search",
      });
      return;
    }
    set({ skillsshSearching: true, skillsshMode: "search" });
    const response = await commands.communitySkillsshSearch(query);
    if (!order.lands(ticket)) return;
    if (response.status === "ok") {
      set({
        skillsshHits: response.data,
        skillsshError: null,
        skillsshSearching: false,
      });
    } else {
      set({ skillsshError: response.error, skillsshSearching: false });
    }
  },

  loadLeaderboard: async (view) => {
    const ticket = order.begin();
    set({ skillsshSearching: true });
    const response = await commands.communitySkillsshLeaderboard(view);
    if (!order.lands(ticket)) return;
    if (response.status === "ok") {
      set({
        skillsshHits: response.data,
        skillsshMode: view,
        skillsshError: null,
        skillsshSearching: false,
      });
    } else {
      // No proxy (or it is down): the chips disappear rather than sit
      // broken; whatever the list showed stays.
      set({ skillsshChips: false, skillsshSearching: false });
    }
  },
}));
