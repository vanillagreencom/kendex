import {
  Blocks,
  BookOpen,
  Bot,
  type LucideIcon,
  Puzzle,
  Server,
  SquareTerminal,
  Webhook,
} from "lucide-react";
import type { ItemKind } from "@/bindings";

// One icon per kind, shared by every page that lists items — a skill
// should look like the same thing whether you're on Library, Updates, or
// Harnesses, so the mapping lives here instead of being redrawn per screen.
const KIND_ICONS: Record<ItemKind, LucideIcon> = {
  skill: BookOpen,
  agent: Bot,
  command: SquareTerminal,
  hook: Webhook,
  "mcp-server": Server,
  plugin: Puzzle,
  "pi-extension": Blocks,
};

export function kindIcon(kind: ItemKind): LucideIcon {
  return KIND_ICONS[kind];
}
