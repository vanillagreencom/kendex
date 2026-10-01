# Output styles

A response style is a Markdown file under `output-styles/<name>.md` in a declared-layout catalog. It changes response wording, not when a skill loads.

## Frontmatter

| Field | kendex requirement | Meaning |
|---|---|---|
| `name` | Required; matches the package name | Claude Code's case-sensitive style selection |
| `description` | Required; non-empty | The description shown in the catalog and style picker |
| `keep-coding-instructions` | Required; `true` | Keeps Claude Code's software engineering instructions |

Claude Code defaults `keep-coding-instructions` to `false` for custom styles. kendex requires `true`. [Claude Code's output-style reference](https://code.claude.com/docs/en/output-styles) defines its native frontmatter and settings interface.

## Declaration

```toml
[output-styles.STE]
source = "kendex"
```

The declaration has the same fields as a skill. `[install] harnesses` and `[install] method` supply the defaults. One scope may declare only one style, including disabled declarations. No new setting selects the kind.

The existing rendered-file and marker writers deliver the style. The lock retains the effective delivery method. A marker block has no filesystem link to install.

## Routes

| Harness | Global | Project |
|---|---|---|
| Claude Code | Native style file and absent-only `outputStyle` | Native style file and absent-only `outputStyle`; no repository `AGENTS.md` block |
| Pi | `APPEND_SYSTEM.md` marker block | `.pi/APPEND_SYSTEM.md` marker block |
| Codex, Copilot CLI, Gemini CLI, OpenCode, Cursor, Antigravity | Unsupported; reported in the plan | Unsupported; no style instruction file is written |

The [adapter pages](../adapters/README.md) state the exact positions and ownership. The catalog check and planner share `crates/core/src/engine/output_style.rs::body`. The route and drift tests are `crates/core/tests/output_styles.rs`.
