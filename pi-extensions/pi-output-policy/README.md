# pi-output-policy

![Output Policy settings panel](https://raw.githubusercontent.com/vanillagreencom/vstack/main/pi-extensions/pi-output-policy/assets/settings-panel.png)

Large-output policy for Pi model responses and tool results: runaway-response interruption, minimization, bounded truncation, and full-output preservation. Tuned to keep degenerate model streams from overwhelming the TUI and long autonomous runs under provider request-buffer limits without losing full tool output (it lands on disk).

## Runaway model output guard

Streaming assistant responses are aborted when either safety condition fires:

- the same substantial line repeats 24 times and contributes at least 1,536 repeated characters; or
- one response reaches 96,000 streamed characters.

Pi keeps the partial response and marks it interrupted; Output Policy shows a warning telling the user to retry or switch models. All thresholds are live settings; changes apply to the next assistant message. The whole model-output guard, repetition detection, and the hard character cap can each be disabled independently.

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

- Stops degenerate streaming model responses before repeated prose or tool tags overwhelm the TUI/session.
- Preserves oversized tool output to disk and includes the artifact path in results.
- Head truncation for search/listing tools; tail truncation for command/log tools.
- Explicit truncation notices show size, line count, direction, artifact path, per-turn/session bytes saved, and continuation guidance.
- Sanitized `details` carry a `vstackOutputPolicySanitized` marker (capped arrays/objects include a sentinel string) so integrators inspecting tool-result payloads can detect it — shape details in `DEVELOPMENT.md`.
- File reads and edit/write results pass through unmodified by default — opt in per category.
- Tool-result `details` are sanitized by default in `balanced`/`compact` (off in `compat`); state-bearing tools (`tasks_write`, `bg_task`, `subagent`, …) bypass sanitization so sidecar restore semantics stay safe.
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

Project settings in `.pi/settings.json` apply only after Pi marks the workspace trusted; before trust, vstack Pi extensions read user/global settings only.

| Group | Setting | What it does |
| --- | --- | --- |
| General | Enable output policy | Master toggle. |
| General | Policy mode | `balanced` (default), `compact`, or `compat`. See [Policy modes](#policy-modes). |
| Model output guard | Stop runaway model output | Enable repetition detection and the hard response-size cap. |
| Model output guard | Maximum streamed characters | Abort one assistant response at this character count; `0` disables only this cap. |
| Model output guard | Detect repeated output | Enable repetition detection independently from the hard character cap. |
| Model output guard | Maximum repeated blocks | Consecutive identical substantial lines required before aborting. |
| Model output guard | Minimum repeated block length | Exclude shorter lines from repetition detection; only blank or recognized syntax-only lines preserve an existing substantial streak. |
| Model output guard | Minimum repeated characters | Repeated-text floor that must also be reached before aborting. |
| Truncation | Truncate file reads | Apply spill/truncation to `read` results. |
| Truncation | Truncate edits/writes | Apply spill/truncation to `edit`/`write` results. |
| Truncation | Output spill threshold (KB) | Preserve full output externally above this size. Unset = mode default. |
| Truncation | Inline tail size (KB) | Bytes kept inline for tail-truncated command/log output. Unset = mode default. |
| Truncation | Inline tail lines | Lines kept inline for tail-truncated command/log output. Unset = mode default. |
| UI safety | Max UI-safe text block (KB) | Hard cap on text blocks even when spill is off. Unset = mode default. |
| UI safety | Max UI-safe line count | Hard line cap for rendered text. Unset = mode default. |
| UI safety | Max UI-safe line width | Truncate pathological wide lines. Unset = mode default. |
| UI safety | Sanitize details payloads | Cap nested tool-result details. Unset = mode default (`balanced`/`compact` on, `compat` off). |
| UI safety | Sanitize details allowlist | Comma-separated tool names whose details bypass sanitization. Empty = built-in list (`tasks_write`, `tasks_read`, `bg_task`, `bg_status`, `subagent`, `subagent_run`, `stop_subagent`, `steer_subagent`, `get_subagent_result`). |
| Storage | Preserve full output externally | Write oversized output to an artifact file when possible. |
| Shell minimizer | Reduce verbose shell output | Compress git/npm/cargo/test output before truncation. On by default; disable when you need full successful build logs inline. |
| Shell minimizer | Allowlist | Comma-separated command families to minimize. |
| Shell minimizer | Denylist | Comma-separated command families to leave alone. |
| Shell minimizer | Max capture bytes | Skip minimizer on output larger than this; truncate directly. |

## Switching back to verbatim behavior

`compat` mode restores the legacy generous UI-safety caps (200 KB block, 8 000 lines, 20 000-char lines) and turns off `sanitizeDetails`, but it is **not** "fully untruncated" — anything above those caps still spills. Pick it when those caps are wide enough for your workflow; for truly untruncated inline output (no spill, no minimizer, no sanitization), disable the policy entirely with `"enabled": false` in place of `"policyMode": "compat"`.

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

## Notes

Pi's built-in tools may truncate before reaching this extension. Custom tools that return full large text benefit most from spill preservation.

For truncated file reads, continue reading the original file with `offset`/`limit`. For truncated command output, the inline notice points at the artifact file on disk and reports per-turn and per-session bytes saved so users can see the transcript impact at a glance.

Contributor-facing budget design, guard mechanics, and sanitization markers are in [`DEVELOPMENT.md`](./DEVELOPMENT.md).
