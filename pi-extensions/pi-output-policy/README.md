# pi-output-policy

![Output Policy settings panel](https://raw.githubusercontent.com/vanillagreencom/vstack/main/pi-extensions/pi-output-policy/assets/settings-panel.png)

Large-output policy for Pi tool results: minimization, bounded truncation, and full-output preservation. Tuned to keep long autonomous runs under provider request-buffer limits without losing the full tool output (it lands on disk).

## Two budgets, one policy

Output policy enforces two related but distinct budgets:

- **Compact renderer UI** — how big a tool block can be without breaking Pi's TUI. Caps line width, hard line count, and absolute block size.
- **Model transcript / session JSONL** — how much each tool result adds to the request body that gets resent on every turn. Long runs with many "fine" 50–200 KB results have crashed with `HTTP 507: exceeded request buffer limit while retrying upstream` even when no individual block was UI-pathological.

Earlier defaults only had teeth on the first budget. The default `balanced` policy mode now also constrains the second, while leaving the full text on disk via per-session artifacts.

## Policy modes

Pick the trade-off via `Policy mode` (or `policyMode` in JSON):

| Mode | Spill (KB) | Inline tail (KB / lines) | Max block (KB) | Max lines | Max line width | sanitizeDetails |
| --- | --- | --- | --- | --- | --- | --- |
| `balanced` (default) | 48 | 16 / 400 | 24 | 400 | 3 000 | on (with allowlist) |
| `compact` | 16 | 6 / 200 | 8 | 200 | 2 000 | on (with allowlist) |
| `compat` | 200 | 100 / 2 000 | 200 | 8 000 | 20 000 | off |

`balanced` keeps any single non-read/non-mutation tool result under ~24 KB inline while preserving the full output to disk. `compact` is for very long autonomous runs that need to stretch the request buffer further. `compat` is the legacy UI-safety-only profile — no transcript-size protection, but it still applies the old caps (200 KB block / 8 000 lines / 20 000-char lines). For truly untruncated inline output, set `enabled: false` instead.

Any per-knob value you set in `vstack.extensionManager.config["@vanillagreen/pi-output-policy"]` overrides the mode default; unset knobs follow the mode.

## Highlights

- Preserves oversized tool output to disk and includes the artifact path in results.
- Head truncation for search/listing tools; tail truncation for command/log tools.
- Explicit truncation notices show size, line count, direction, artifact path, per-turn/session bytes saved, and continuation guidance.
- File reads and edit/write results pass through unmodified by default — opt in per category.
- Tool-result `details` are sanitized by default in `balanced`/`compact` (off in `compat`); state-bearing tools (`tasks_write`, `bg_task`, `subagent`, …) bypass sanitization so sidecar restore semantics stay safe.
- When `details` are sanitized, the result carries a `vstackOutputPolicySanitized` marker (and capped arrays/objects include a sentinel string) so consumers can detect the truncation.
- Shell output minimizer compresses noisy git/npm/cargo/test output before truncation while preserving warnings, errors, and summaries.

## Install

Via [npm](https://www.npmjs.com/package/@vanillagreen/pi-output-policy):

```bash
pi install npm:@vanillagreen/pi-output-policy
```

Via [vstack](https://github.com/vanillagreencom/vstack):

```bash
cargo install --git https://github.com/vanillagreencom/vstack.git vstack
vstack add vanillagreencom/vstack --pi-extension pi-output-policy --harness pi -y
```

Restart Pi after installation.

## Settings

Open `/extensions:settings`; settings appear under the **Output Policy** tab.

### General

| Setting | What it does |
| --- | --- |
| Enable output policy | Master toggle. |
| Policy mode | `balanced` (default), `compact`, or `compat`. See [Policy modes](#policy-modes). |

### Truncation

| Setting | What it does |
| --- | --- |
| Truncate file reads | Apply spill/truncation to `read` results. |
| Truncate edits/writes | Apply spill/truncation to `edit`/`write` results. |
| Output spill threshold (KB) | Preserve full output externally above this size. Unset = mode default. |
| Inline tail size (KB) | Bytes kept inline for tail-truncated command/log output. Unset = mode default. |
| Inline tail lines | Lines kept inline for tail-truncated command/log output. Unset = mode default. |

### UI safety

| Setting | What it does |
| --- | --- |
| Max UI-safe text block (KB) | Hard cap on text blocks even when spill is off. Unset = mode default. |
| Max UI-safe line count | Hard line cap for rendered text. Unset = mode default. |
| Max UI-safe line width | Truncate pathological wide lines. Unset = mode default. |
| Sanitize details payloads | Cap nested tool-result details. Unset = mode default (`balanced`/`compact` on, `compat` off). |
| Sanitize details allowlist | Comma-separated tool names whose details bypass sanitization. Empty = built-in list (`tasks_write`, `tasks_read`, `bg_task`, `bg_status`, `subagent`, `subagent_run`, `stop_subagent`, `steer_subagent`, `get_subagent_result`). |

### Storage

| Setting | What it does |
| --- | --- |
| Preserve full output externally | Write oversized output to an artifact file when possible. |

### Shell minimizer

| Setting | What it does |
| --- | --- |
| Reduce verbose shell output | Compress git/npm/cargo/test output before truncation. On by default; disable when you need full successful build logs inline. |
| Allowlist | Comma-separated command families to minimize. |
| Denylist | Comma-separated command families to leave alone. |
| Max capture bytes | Skip minimizer on output larger than this; truncate directly. |

## Switching back to verbatim behavior

`compat` mode restores the legacy generous UI-safety caps (200 KB block, 8 000 lines, 20 000-char lines) and turns off `sanitizeDetails`, but it is **not** "fully untruncated" — anything above those caps still spills. Pick it when those caps are wide enough for your workflow:

```json
{
  "vstack": {
    "extensionManager": {
      "config": {
        "@vanillagreen/pi-output-policy": {
          "policyMode": "compat"
        }
      }
    }
  }
}
```

For truly untruncated inline output (no spill, no minimizer, no sanitization), disable the policy entirely:

```json
{
  "vstack": {
    "extensionManager": {
      "config": {
        "@vanillagreen/pi-output-policy": { "enabled": false }
      }
    }
  }
}
```

## Notes

Pi's built-in tools may truncate before reaching this extension. Custom tools that return full large text benefit most from spill preservation.

For truncated file reads, continue reading the original file with `offset`/`limit`. For truncated command output, the inline notice points at the artifact file on disk and reports per-turn and per-session bytes saved so users can see the transcript impact at a glance.

Extension-produced custom messages (`pi.sendMessage`) are not policed by this extension; add per-package caps in extensions that emit large custom messages.
