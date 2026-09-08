// @vitest-environment jsdom
import { act } from "react";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { AGE_TICK_MS } from "@/lib/use-now-tick";
import { mount } from "@/test/dom";
import { Ago } from "./ago";

beforeEach(() => vi.useFakeTimers());
afterEach(() => vi.useRealTimers());

it("ages an Ago label with no render of its own to prompt it", () => {
  const host = mount(<Ago at={Date.now()} />);
  expect(host.textContent).toContain("just now");

  act(() => {
    vi.advanceTimersByTime(90_000 + AGE_TICK_MS);
  });

  expect(host.textContent).toContain("2m ago");
  expect(host.textContent).not.toContain("just now");
});
