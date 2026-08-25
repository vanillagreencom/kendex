import { create } from "zustand";

/** What the Updates tables show beyond the standing itself: the Version
 *  column — commit ids, meaningful to few — stays off until someone asks
 *  from the table's `…` menu. A choice for the session, kept apart from
 *  the standing so leaving the page and coming back keeps it. */
interface UpdatesViewState {
  showVersion: boolean;
  setShowVersion: (show: boolean) => void;
}

export const useUpdatesView = create<UpdatesViewState>((set) => ({
  showVersion: false,
  setShowVersion: (show) => set({ showVersion: show }),
}));
