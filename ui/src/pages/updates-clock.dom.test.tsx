// @vitest-environment jsdom
import { act } from "react";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { Ago } from "@/components/ago";
import { updateRow } from "@/components/updates-test-rows";
import { READ_LANDED } from "@/lib/read-state";
import { AGE_TICK_MS } from "@/lib/use-now-tick";
import { useUpdatesStore } from "@/stores/updates";
import { mount } from "@/test/dom";
import { UpdatesPage } from "./updates";

// Age labels and the one clock behind them. Nothing a page does re-renders
// often enough to keep an age honest — a window left open overnight would be
// showing the age it had when it opened, which is the frozen claim these
// exist to remove. Two surfaces, one rate: the Updates page composes its age
// into a sentence, and `<Ago>` is what every table row and header draws.
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

// A table draws one of these per row and a marketplace header draws another,
// none of which re-render on anything in particular. Sampling the clock at
// render leaves the reading frozen for as long as the tab stays open, which
// is the one thing worse than not saying it — the exact moment stays on the
// title either way, and that is not what the eye reads.
it("ages an Ago label with no render of its own to prompt it", () => {
  const host = mount(<Ago at={Date.now()} />);
  expect(host.textContent).toContain("just now");

  act(() => {
    vi.advanceTimersByTime(90_000 + AGE_TICK_MS);
  });

  expect(host.textContent).toContain("2m ago");
  expect(host.textContent).not.toContain("just now");
});
