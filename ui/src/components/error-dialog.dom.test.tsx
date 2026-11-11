// @vitest-environment jsdom
import { act } from "react";
import { expect, it, vi } from "vitest";
import { useProblemsStore } from "@/stores/problems";
import { mount } from "@/test/dom";
import { ErrorDialog } from "./error-dialog";

vi.mock("@/bindings", () => ({ commands: {} }));

// A failed write is a Result, and the dialog that reports it wears the
// failed tone on its title.
it("titles a failed write in the failed Result tone", () => {
  mount(<ErrorDialog />);
  act(() => {
    useProblemsStore.getState().showError({ title: "Couldn't save" });
  });
  const title = document.body.querySelector('[role="dialog"] .text-critical');
  expect(title?.textContent).toBe("Couldn't save");
});

// A run's failures each stand under their own title, and a control acts
// on the failure it sits under: a footer of two Retry buttons could not
// say which one retries what.
it("states every failure of one run, each with its own controls", async () => {
  const retried: string[] = [];
  mount(<ErrorDialog />);
  await act(() =>
    useProblemsStore.getState().inOneRun(async () => {
      useProblemsStore.getState().showError({
        title: "gh: a step after the change failed",
        message: "render: denied",
      });
      useProblemsStore.getState().showError({
        title: "Couldn't start managing lint",
        message: "lint is locked",
        actions: [{ label: "Retry", onClick: () => retried.push("lint") }],
      });
    }),
  );
  const dialog = document.body.querySelector('[role="dialog"]');
  const sections = [...(dialog?.querySelectorAll("section") ?? [])];
  expect(
    sections.map((section) => [
      section.querySelector("h3")?.textContent,
      section.querySelector("p")?.textContent,
    ]),
  ).toEqual([
    ["gh: a step after the change failed", "render: denied"],
    ["Couldn't start managing lint", "lint is locked"],
  ]);

  const retry = sections[1].querySelector("button");
  act(() => retry?.click());

  expect(retried).toEqual(["lint"]);
  expect(useProblemsStore.getState().dialog.open).toBe(false);
});
