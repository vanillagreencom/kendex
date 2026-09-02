import type { ItemKind } from "@/bindings";

/**
 * The kinds "Manage these files" works for. Every real `AuditView` carries
 * this list from core's own `adopt::supports`, so no surface keeps a copy
 * of it; this one exists for fixtures and tests, which build views by hand
 * and should render what the product renders.
 */
export const ADOPTABLE: ItemKind[] = ["agent", "skill"];
