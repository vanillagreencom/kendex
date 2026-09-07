// A file the scan could not read as the document its surface expects. The
// core says whose file it is and the shape of what is wrong; the words
// here turn that into what the reader sees and what they can do about it.
import type { ScanWarning } from "@/bindings";
import { harnessName, kindLabel } from "@/lib/labels";

/** The kind's label mid-sentence: "hooks", "MCP servers". Lowercased
 *  unless it opens with an acronym, which the second letter tells. */
const kindNoun = (warning: ScanWarning): string => {
  const label = kindLabel(warning.kind, 2);
  const acronym = label.charAt(1) !== label.charAt(1).toLowerCase();
  return acronym ? label : label.charAt(0).toLowerCase() + label.slice(1);
};

/** The file, named by the tool that reads it and what it holds — the one
 *  phrase every line about it opens with. */
const fileOf = (warning: ScanWarning): string =>
  `${harnessName(warning.harness)}'s ${kindNoun(warning)} file`;

/** What is wrong, as a title: which tool's file, and the shape of it. */
export const unreadableFileTitle = (warning: ScanWarning): string => {
  const file = fileOf(warning);
  switch (warning.problem.kind) {
    case "empty-file":
      return `${file} is empty`;
    case "invalid-json":
      return `${file} isn't valid JSON`;
    case "invalid-toml":
      return `${file} isn't valid TOML`;
    case "unreadable":
      return `${file} can't be read`;
    case "unknown-tag":
      return `A tag in ${file} isn't one kendex knows`;
  }
};

/** What to do about it. An empty file is another tool's leftover and the
 *  remedy is the reader's; a malformed one names where the parser
 *  stopped; an unreadable one is a permissions question. */
export const unreadableFileRemedy = (warning: ScanWarning): string => {
  switch (warning.problem.kind) {
    case "empty-file":
      return "Delete it, or put {} in it, then scan again.";
    case "invalid-json":
    case "invalid-toml":
      return `Fix it where the parser stopped: ${warning.problem.message}. Then scan again.`;
    case "unreadable":
      return `kendex couldn't open it: ${warning.problem.message}. Check its permissions, then scan again.`;
    case "unknown-tag":
      return `${warning.problem.message} Fix the tags line, then scan again.`;
  }
};

/** Home's one line for the file: where it is, then what to do. */
export const unreadableFileDetail = (warning: ScanWarning): string =>
  `${warning.path} — ${unreadableFileRemedy(warning)}`;

export const SHOW_IN_FILE_BROWSER_LABEL = "Show in file browser";
export const RESCAN_LABEL = "Rescan";
