import type { DeclaredSkillRow, Manifest_Serialize } from "@/bindings";

/** The engine's `[agent-skills]` lookup, stood in for by the dev shell:
 *  an agent reads its own row, and a `reviewer-` agent with none reads its
 *  base agent's. The real answer comes from
 *  `crates/core/src/mapping.rs::declared_skills`; nothing outside this
 *  file may reimplement it, which is why the shell keeps its stand-in
 *  here beside its other canned answers rather than in the app. */
export function declaredSkillRows(
  manifest: Manifest_Serialize | undefined,
): Record<string, DeclaredSkillRow> {
  const rows = manifest?.["agent-skills"] ?? {};
  const out: Record<string, DeclaredSkillRow> = {};
  for (const agent of Object.keys(manifest?.agents ?? {})) {
    const own = rows[agent];
    if (own) {
      out[agent] = { skills: own, under: agent };
      continue;
    }
    const base = agent.replace(/^reviewer-/, "");
    const inherited = base === agent ? undefined : rows[base];
    if (inherited) out[agent] = { skills: inherited, under: base };
  }
  return out;
}
