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

  const controls = (start = 100) => {
    let shown = start;
    const preview = vi.fn((percent: number) => {
      shown = percent;
    });
    const save = vi.fn();
    return {
      preview,
      save,
      zoom: zoomControls({ current: () => shown, preview, save }),
    };
  };

  it("resizes on every press and writes once the presses stop", () => {
    const { preview, save, zoom } = controls();

    expect(zoom.onKeyDown(press("+"))).toBe(true);
    vi.advanceTimersByTime(ZOOM_SETTLE_MS - 1);
    expect(zoom.onKeyDown(press("+"))).toBe(true);
    vi.advanceTimersByTime(ZOOM_SETTLE_MS - 1);
    expect(zoom.onKeyDown(press("+"))).toBe(true);

    // A held key repeats faster than the size is written.
    expect(preview).toHaveBeenCalledTimes(3);
    expect(save).not.toHaveBeenCalled();

    vi.advanceTimersByTime(ZOOM_SETTLE_MS);
    expect(save).toHaveBeenCalledTimes(1);
  });

  it("leaves a press that means something else alone", () => {
    const { preview, save, zoom } = controls();

    expect(zoom.onKeyDown(press("a"))).toBe(false);
    vi.advanceTimersByTime(ZOOM_SETTLE_MS * 2);
    expect(preview).not.toHaveBeenCalled();
    expect(save).not.toHaveBeenCalled();
  });

  it("resizes by one step a press, and writes once the clicking stops", () => {
    const { preview, save, zoom } = controls();

    zoom.step(ZOOM.step);
    vi.advanceTimersByTime(ZOOM_SETTLE_MS - 1);
    zoom.step(ZOOM.step);
    vi.advanceTimersByTime(ZOOM_SETTLE_MS - 1);
    zoom.step(-ZOOM.step);

    expect(preview.mock.calls.map(([percent]) => percent)).toEqual([
      110, 120, 110,
    ]);
    // Clicked faster than the file is written, exactly as a held key is.
    expect(save).not.toHaveBeenCalled();

    vi.advanceTimersByTime(ZOOM_SETTLE_MS);
    expect(save).toHaveBeenCalledTimes(1);
  });

  it("stops at the ends of the range rather than running past them", () => {
    const top = controls(ZOOM.max);
    top.zoom.step(ZOOM.step);
    expect(top.preview).toHaveBeenLastCalledWith(ZOOM.max);

    const bottom = controls(ZOOM.min);
    bottom.zoom.step(-ZOOM.step);
    expect(bottom.preview).toHaveBeenLastCalledWith(ZOOM.min);
  });

  /// Two presses inside one render frame both have to count: reading the
  /// size back from what the page last drew loses the second.
  it("counts every press, even two before anything redraws", () => {
    const { preview, zoom } = controls();

    zoom.step(ZOOM.step);
    zoom.step(ZOOM.step);
    zoom.step(ZOOM.step);

    expect(preview.mock.calls.map(([percent]) => percent)).toEqual([
      110, 120, 130,
    ]);
  });

  it("writes a pending size at once when the app is going away", () => {
    const { save, zoom } = controls();

    zoom.onKeyDown(press("+"));
    zoom.flush();

    expect(save).toHaveBeenCalledTimes(1);
    // The settle it replaced does not fire a second write behind it.
    vi.advanceTimersByTime(ZOOM_SETTLE_MS * 2);
    expect(save).toHaveBeenCalledTimes(1);
  });

  /// The window opens before the settings that hold its size have loaded.
  /// A press then has nothing to act on, and a size guessed from a default
  /// would move the window somewhere nobody asked for.
  it("does nothing, and takes nothing, before the size is known", () => {
    const preview = vi.fn();
    const save = vi.fn();
    const zoom = zoomControls({ current: () => null, preview, save });

    expect(zoom.onKeyDown(press("+"))).toBe(false);
    zoom.step(ZOOM.step);
    vi.advanceTimersByTime(ZOOM_SETTLE_MS * 2);

    expect(preview).not.toHaveBeenCalled();
    expect(save).not.toHaveBeenCalled();
  });

  it("writes nothing on the way out when nothing is pending", () => {
    const { save, zoom } = controls();

    zoom.flush();
    zoom.onKeyDown(press("+"));
    vi.advanceTimersByTime(ZOOM_SETTLE_MS);
    zoom.flush();

    expect(save).toHaveBeenCalledTimes(1);
  });
});
