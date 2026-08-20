import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { ZOOM } from "@/bindings";
import { ZOOM_SETTLE_MS, zoomControls, zoomForKey } from "./zoom-controls";

const press = (key: string, extra: Record<string, boolean> = {}) => ({
  key,
  ctrlKey: true,
  metaKey: false,
  altKey: false,
  ...extra,
});

describe("zoomForKey", () => {
  it("steps in and out, and resets to full size", () => {
    expect(zoomForKey(press("+"), 100)).toBe(100 + ZOOM.step);
    expect(zoomForKey(press("="), 100)).toBe(100 + ZOOM.step);
    expect(zoomForKey(press("-"), 100)).toBe(100 - ZOOM.step);
    expect(zoomForKey(press("_"), 100)).toBe(100 - ZOOM.step);
    expect(zoomForKey(press("0"), 175)).toBe(ZOOM.default);
  });

  it("stops at the ends of the range instead of running past them", () => {
    expect(zoomForKey(press("+"), ZOOM.max)).toBe(ZOOM.max);
    expect(zoomForKey(press("-"), ZOOM.min)).toBe(ZOOM.min);
  });

  it("takes Cmd as well as Ctrl", () => {
    expect(zoomForKey(press("+", { ctrlKey: false, metaKey: true }), 100)).toBe(
      100 + ZOOM.step,
    );
  });

  it("leaves every other press alone", () => {
    expect(zoomForKey(press("+", { ctrlKey: false }), 100)).toBeNull();
    expect(zoomForKey(press("+", { altKey: true }), 100)).toBeNull();
    expect(zoomForKey(press("a"), 100)).toBeNull();
    expect(zoomForKey(press("1"), 100)).toBeNull();
  });
});

describe("ZOOM_SETTLE_MS", () => {
  // Held keys repeat every 30-50ms on the usual settings, and a slider under
  // an arrow key commits once per repeat. A settle inside that range is not
  // a settle at all: the file gets rewritten for the whole hold.
  it("outlasts the keyboard's repeat interval", () => {
    expect(ZOOM_SETTLE_MS).toBeGreaterThanOrEqual(150);
  });
});

describe("zoomControls", () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  const controls = () => {
    const preview = vi.fn();
    const save = vi.fn();
    return { preview, save, zoom: zoomControls(preview, save) };
  };

  it("resizes on every press and writes once the presses stop", () => {
    const { preview, save, zoom } = controls();

    expect(zoom.onKeyDown(press("+"), 100)).toBe(true);
    vi.advanceTimersByTime(ZOOM_SETTLE_MS - 1);
    expect(zoom.onKeyDown(press("+"), 110)).toBe(true);
    vi.advanceTimersByTime(ZOOM_SETTLE_MS - 1);
    expect(zoom.onKeyDown(press("+"), 120)).toBe(true);

    // A held key repeats faster than the size is written.
    expect(preview).toHaveBeenCalledTimes(3);
    expect(save).not.toHaveBeenCalled();

    vi.advanceTimersByTime(ZOOM_SETTLE_MS);
    expect(save).toHaveBeenCalledTimes(1);
  });

  it("leaves a press that means something else alone", () => {
    const { preview, save, zoom } = controls();

    expect(zoom.onKeyDown(press("a"), 100)).toBe(false);
    vi.advanceTimersByTime(ZOOM_SETTLE_MS * 2);
    expect(preview).not.toHaveBeenCalled();
    expect(save).not.toHaveBeenCalled();
  });

  it("resizes as the slider moves and writes nothing until it stops", () => {
    const { preview, save, zoom } = controls();

    zoom.slider.onValueChange(110);
    zoom.slider.onValueChange(120);

    expect(preview).toHaveBeenCalledTimes(2);
    expect(preview).toHaveBeenLastCalledWith(120);
    vi.advanceTimersByTime(ZOOM_SETTLE_MS * 2);
    expect(save).not.toHaveBeenCalled();
  });

  /// An arrow key on the focused slider commits once per press, so the
  /// slider needs the same settle the shortcut has.
  it("writes once for a run of slider commits", () => {
    const { save, zoom } = controls();

    zoom.slider.onValueCommitted();
    vi.advanceTimersByTime(ZOOM_SETTLE_MS - 1);
    zoom.slider.onValueCommitted();
    vi.advanceTimersByTime(ZOOM_SETTLE_MS - 1);
    zoom.slider.onValueCommitted();
    expect(save).not.toHaveBeenCalled();

    vi.advanceTimersByTime(ZOOM_SETTLE_MS);
    expect(save).toHaveBeenCalledTimes(1);
  });

  it("drops a pending write when the window it would talk to is going away", () => {
    const { save, zoom } = controls();

    zoom.onKeyDown(press("+"), 100);
    zoom.cancel();
    vi.advanceTimersByTime(ZOOM_SETTLE_MS * 2);

    expect(save).not.toHaveBeenCalled();
  });
});
