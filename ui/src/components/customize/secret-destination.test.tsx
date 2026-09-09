// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import type { SecretsView } from "@/bindings";
import {
  SECRET_FILE_CHANGE,
  SECRET_FILE_RECORDED,
  SECRET_FILE_REFUSED,
  SECRET_FILE_WILL_CREATE,
  SECRET_FILE_WILL_IGNORE,
} from "@/lib/copy-customize";
import { mount } from "@/test/dom";
import { SecretDestination } from "./secret-destination";

const view = (over: Partial<SecretsView> = {}): SecretsView => ({
  destination: { file: ".env.local", chosen: false, state: { state: "ready" } },
  candidates: [],
  base: "p1",
  ...over,
});

const render = (
  read: SecretsView,
  picked: string | null = null,
  onPick: (file: string | null) => void = () => {},
) =>
  mount(<SecretDestination secrets={read} picked={picked} onPick={onPick} />);

describe("SecretDestination", () => {
  it("names the file a value would go to", () => {
    expect(render(view()).textContent).toContain(".env.local");
  });

  /// Saving into a file that is not there yet makes it and keeps git off
  /// it. Both are said before Save, because both are writes.
  it("says what saving will make and what it will ignore first", () => {
    const host = render(
      view({
        destination: {
          file: ".env.local",
          chosen: false,
          state: { state: "missing", ignore: "/.env.local" },
        },
      }),
    );
    expect(host.textContent).toContain(SECRET_FILE_WILL_CREATE(".env.local"));
    expect(host.textContent).toContain(
      SECRET_FILE_WILL_IGNORE("/.env.local", ".env.local"),
    );
  });

  /// A destination git already ignores owes no rule, so nothing about
  /// .gitignore is claimed.
  it("claims no ignore rule where git already ignores the file", () => {
    const host = render(
      view({
        destination: {
          file: ".env.local",
          chosen: false,
          state: { state: "missing", ignore: null },
        },
      }),
    );
    expect(host.textContent).toContain(SECRET_FILE_WILL_CREATE(".env.local"));
    expect(host.textContent).not.toContain(".gitignore");
  });

  /// A refusal is what a person acts on, so the problem and the way out
  /// are both on screen.
  it("shows a refused destination with what to do about it", () => {
    const host = render(
      view({
        destination: {
          file: ".env.local",
          chosen: false,
          state: {
            state: "refused",
            problem: "git already tracks .env.local",
            fix: "run git rm --cached -- .env.local",
          },
        },
      }),
    );
    expect(host.textContent).toContain(SECRET_FILE_REFUSED);
    expect(host.textContent).toContain("git already tracks .env.local");
    expect(host.textContent).toContain("run git rm --cached -- .env.local");
  });

  /// Picking is a read, not a claim: the page asks what that file would
  /// mean before the person saves it.
  it("hands the picked file up rather than assuming what it holds", async () => {
    const onPick = vi.fn();
    const host = render(view({ candidates: [".env.secrets"] }), null, onPick);
    const change = [...host.querySelectorAll("button")].find(
      (one) => one.textContent === SECRET_FILE_CHANGE,
    );
    if (!change) throw new Error("the destination offered no change");
    await userEvent.click(change);
    const pick = [...host.querySelectorAll("button")].find(
      (one) => one.textContent === ".env.secrets",
    );
    if (!pick) throw new Error("the candidate was not offered");
    await userEvent.click(pick);
    expect(onPick).toHaveBeenCalledWith(".env.secrets");
  });

  /// Naming a file the project does not already name is recorded by the
  /// save, so the packages read it too — said before Save rather than
  /// discovered in the settings file afterwards.
  it("says a picked file will be recorded for the packages", () => {
    const host = render(
      view({
        destination: {
          file: ".env.secrets",
          chosen: false,
          state: { state: "ready" },
        },
      }),
      ".env.secrets",
    );
    expect(host.textContent).toContain(SECRET_FILE_RECORDED(".env.secrets"));
  });

  /// A project that already names its file records nothing: the line is
  /// there, and saying it again would promise a write that does not
  /// happen.
  it("promises no record for a file the project already names", () => {
    const host = render(
      view({
        destination: {
          file: ".env.secrets",
          chosen: true,
          state: { state: "ready" },
        },
      }),
      ".env.secrets",
    );
    expect(host.textContent).not.toContain(
      SECRET_FILE_RECORDED(".env.secrets"),
    );
  });
});
