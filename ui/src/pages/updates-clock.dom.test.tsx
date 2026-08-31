// @vitest-environment jsdom
import { act } from "react";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { updateRow } from "@/components/updates-test-rows";
import { READ_LANDED } from "@/lib/read-state";
import { AGE_TICK_MS } from "@/lib/use-now-tick";
import { useUpdatesStore } from "@/stores/updates";
import { mount } from "@/test/dom";
import { UpdatesPage } from "./updates";

// Only a read of the standing re-renders this page, and reads happen on
// mount, on a check, and after a mutation. A window left open overnight
// would otherwise still be showing the age it had when it opened — the
// same frozen claim the hint exists to remove.
//
// The store is real; `load` is stubbed to a no-op so the mount effect
// reaches no command and the age on screen can only come from the clock.
beforeEach(() => {
  vi.useFakeTimers();
  useUpdatesStore.setState({
    rows: [updateRow("gh", null)],
    warnings: [],
    lastFetched: Math.floor(Date.now() / 1000),
    busy: false,
    read: READ_LANDED,
    checking: false,
    pendingFollows: [],
    reload: async () => {},
  });
});

afterEach(() => {
  vi.useRealTimers();
});

it("ages the Last checked label on its own, with no read of the standing", () => {
  const host = mount(<UpdatesPage />);
  expect(host.textContent).toContain("Last checked just now");

  const before = useUpdatesStore.getState();
  act(() => {
    vi.advanceTimersByTime(90_000 + AGE_TICK_MS);
  });

  expect(host.textContent).toContain("Last checked 2m ago");
  expect(host.textContent).not.toContain("just now");
  expect(useUpdatesStore.getState().rows).toBe(before.rows);
  expect(useUpdatesStore.getState().lastFetched).toBe(before.lastFetched);
});
