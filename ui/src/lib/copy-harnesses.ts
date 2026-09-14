import type { HarnessId } from "@/bindings";
import { harnessName } from "@/lib/labels";

// The Harnesses page and the harness folder it sets: what a harness is,
// the page with none found, and a folder change that failed.

/** The first line a person reads about harnesses on this page, so it says
 *  what one is in the same sentence. */
export const HARNESSES_SUBTITLE =
  "Harnesses are the AI coding assistants, such as Claude Code and Codex, that kendex installs packages into on this computer";
export const NO_HARNESSES_TITLE = "No harnesses found on this computer.";
export const NO_HARNESSES_BODY =
  "Install Claude Code, Codex, OpenCode, Cursor, Pi, Gemini CLI, GitHub Copilot or Antigravity, then scan again.";
export const NO_PROJECTS_YET =
  "No projects yet. Add a project to install packages into it.";
export const harnessFolderFailedTitle = (harness: HarnessId): string =>
  `Couldn't change where ${harnessName(harness)} keeps its files`;
