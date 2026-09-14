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
