import type { ReactNode } from "react";

/** One file a surface wants listed, with whatever that surface says about
 *  it — a size, a `+n −n` pair, a status word — drawn at the row's right
 *  edge. The path is forward-slashed and relative to whatever root the
 *  surface is about, which is what every producer in the app already
 *  emits. */
export interface FileEntry {
  path: string;
  meta?: ReactNode;
}

/** A folder, or a file inside one. Folders carry their children; a file
 *  carries the entry it was built from, so a row can draw its meta without
 *  a second lookup.
 *
 *  `key` is what tells two nodes apart: one name can be a file and a
 *  folder at once — a comparison that replaces `foo` with `foo/bar` holds
 *  both — so the path alone does not identify a row. */
export type TreeNode =
  | {
      kind: "folder";
      key: string;
      name: string;
      path: string;
      children: TreeNode[];
    }
  | { kind: "file"; key: string; name: string; path: string; entry: FileEntry };

/** What one name holds at one level. Both halves at once is the case a
 *  file-into-directory replacement reaches, and both are drawn. */
interface Held {
  folder?: Folder;
  file?: FileEntry;
}

interface Folder {
  children: Map<string, Held>;
}

/** Group flat paths into folders, the way a code editor shows a checkout.
 *
 *  Two files under `a/b/` share one `a` and one `a/b`. Folders come before
 *  files at every level and each run is sorted by name, so the same set of
 *  paths always draws the same tree whatever order the producer listed
 *  them in.
 *
 *  A name that is a file on one row and a folder on another keeps both.
 *  One comparison can hold `foo` removed and `foo/bar` added — that is what
 *  replacing a file with a directory looks like — and dropping either would
 *  leave a change the person cannot open at all.
 *
 *  A path segment that is empty — a leading, doubled or trailing slash —
 *  is dropped rather than drawn as a nameless folder; a path left with no
 *  segments at all is not a file and is dropped whole. */
export function buildFileTree(entries: FileEntry[]): TreeNode[] {
  const root: Folder = { children: new Map() };
  for (const entry of entries) {
    const segments = entry.path.split("/").filter((one) => one !== "");
    const name = segments.pop();
    if (name === undefined) continue;
    let at = root;
    for (const segment of segments) {
      const held = hold(at, segment);
      held.folder ??= { children: new Map() };
      at = held.folder;
    }
    hold(at, name).file = entry;
  }
  return nodesOf(root, "");
}

function hold(folder: Folder, name: string): Held {
  const found = folder.children.get(name);
  if (found !== undefined) return found;
  const made: Held = {};
  folder.children.set(name, made);
  return made;
}

function nodesOf(folder: Folder, prefix: string): TreeNode[] {
  const folders: TreeNode[] = [];
  const files: TreeNode[] = [];
  for (const [name, held] of folder.children) {
    const path = prefix === "" ? name : `${prefix}/${name}`;
    if (held.folder) {
      folders.push({
        kind: "folder",
        key: `folder:${path}`,
        name,
        path,
        children: nodesOf(held.folder, path),
      });
    }
    if (held.file) {
      files.push({
        kind: "file",
        key: `file:${held.file.path}`,
        name,
        path: held.file.path,
        entry: held.file,
      });
    }
  }
  const byName = (a: TreeNode, b: TreeNode) => a.name.localeCompare(b.name);
  folders.sort(byName);
  files.sort(byName);
  return [...folders, ...files];
}
