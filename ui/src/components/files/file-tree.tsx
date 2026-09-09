import { ChevronDown, ChevronRight, FileText, Folder } from "lucide-react";
import { useMemo, useState } from "react";
import {
  buildFileTree,
  type FileEntry,
  type TreeNode,
} from "@/components/files/file-tree-model";
import { cn } from "@/lib/utils";

/** The app's one way to list files: a tree with folders that open and
 *  close, indented so the structure reads at a glance, the way a code
 *  editor shows a checkout.
 *
 *  Indentation is the nesting itself — a folder's contents are a list
 *  inside its own row's list, shifted one step and drawn against a guide
 *  rule — so no row has to be told how deep it is and every level lines up
 *  with the one above it whatever the tree holds.
 *
 *  Every folder starts open. A package, a set of changed files and a
 *  planned install are all small enough that their shape is the useful
 *  thing; folders a reader closes stay closed for as long as the tree is
 *  on screen. */
export function FileTree({
  entries,
  selected,
  onSelect,
  label,
  className,
}: {
  entries: FileEntry[];
  /** The path drawn as chosen, or null where the surface has none. */
  selected: string | null;
  onSelect: (path: string) => void;
  /** What this tree is a tree of, for screen readers. */
  label: string;
  className?: string;
}) {
  const nodes = useMemo(() => buildFileTree(entries), [entries]);
  // Closed rather than open, so a tree that gains a folder opens it: the
  // set a reader has closed is the smaller and the more deliberate half.
  // Keyed by the folder's own key rather than its path, which one name can
  // share with a file beside it.
  const [closed, setClosed] = useState<ReadonlySet<string>>(new Set());
  const toggle = (key: string) =>
    setClosed((was) => {
      const next = new Set(was);
      if (!next.delete(key)) next.add(key);
      return next;
    });
  return (
    <ul aria-label={label} className={cn("min-w-0", className)}>
      {nodes.map((node) => (
        <Row
          key={node.key}
          node={node}
          closed={closed}
          selected={selected}
          onSelect={onSelect}
          onToggle={toggle}
        />
      ))}
    </ul>
  );
}

const ROW =
  "flex w-full items-center gap-1.5 rounded-md py-1 pr-2 pl-1.5 text-left text-sm hover:bg-accent";

function Row({
  node,
  closed,
  selected,
  onSelect,
  onToggle,
}: {
  node: TreeNode;
  closed: ReadonlySet<string>;
  selected: string | null;
  onSelect: (path: string) => void;
  onToggle: (key: string) => void;
}) {
  if (node.kind === "file") {
    const chosen = selected === node.path;
    return (
      <li>
        <button
          type="button"
          aria-current={chosen ? "true" : undefined}
          title={node.path}
          className={cn(ROW, chosen && "bg-muted font-medium")}
          onClick={() => onSelect(node.path)}
        >
          {/* The lane a folder's chevron sits in, so a file's icon lines
              up with the icon of every folder beside it. */}
          <span className="w-3.5 shrink-0" />
          <FileText className="size-3.5 shrink-0 text-muted-foreground" />
          <span className="min-w-0 truncate">{node.name}</span>
          {node.entry.meta !== undefined ? (
            <span className="ml-auto shrink-0 pl-2 text-xs text-muted-foreground tabular-nums">
              {node.entry.meta}
            </span>
          ) : null}
        </button>
      </li>
    );
  }
  const open = !closed.has(node.key);
  const Chevron = open ? ChevronDown : ChevronRight;
  return (
    <li>
      <button
        type="button"
        aria-expanded={open}
        title={node.path}
        className={ROW}
        onClick={() => onToggle(node.key)}
      >
        <Chevron className="size-3.5 shrink-0 text-muted-foreground" />
        <Folder className="size-3.5 shrink-0 text-muted-foreground" />
        <span className="min-w-0 truncate">{node.name}</span>
      </button>
      {open ? (
        // The rule runs under the folder's own chevron, so the eye follows
        // one line from a folder down past everything inside it.
        <ul className="ml-[0.95rem] border-l border-border/60 pl-1">
          {node.children.map((child) => (
            <Row
              key={child.key}
              node={child}
              closed={closed}
              selected={selected}
              onSelect={onSelect}
              onToggle={onToggle}
            />
          ))}
        </ul>
      ) : null}
    </li>
  );
}
