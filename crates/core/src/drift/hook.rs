//! The session-start drift hook: first-party content shipped inside kendex
//! itself, never fetched from a catalog — it injects into agent context,
//! and its install must not depend on catalog availability. It is still a
//! declared, user-approved install per scope: the plan writes the script
//! into the scope's local source and declares it like any other hook, so
//! every later refresh, verify, and removal treats it as an ordinary
//! installation.

use crate::apply::{Op, Plan, PlannedOp, Pre};
use crate::env::Env;
use crate::error::Result;
use crate::manifest::{ItemDecl, LOCAL_SOURCE_NAME};
use crate::model::{HarnessId, Scope};

pub const HOOK_NAME: &str = "kendex-drift";

/// The session-start script. Its header defines the CLI report protocol and
/// the stable keys of notices the hook adds. It never blocks a session.
pub const HOOK_SCRIPT: &str = r#"#!/bin/sh
# ---
# name: kendex-drift
# event: SessionStart
# description: Prints a short drift report at session start, nothing when clean
# timeout: 20
# harnesses: [claude-code, pi]
# ---
# kendex check --quiet protocol: exit 0 is silent, exit 1 relays the report.
# Exit 2 with empty output or a leading Error:/error: is a pre-check failure;
# other exit-2 output is an incomplete report. Other exits are failures.
# Error:/error: belongs to the CLI's parsed error protocol. The remaining
# report is opaque data; Claude and Pi receive it without interpretation.
# Shell substitution removes trailing newlines; a relayed report gets one.
# Hook notices start with a stable key and command or exit value. English
# follows on the next line, then any report. The hook always exits 0.

notice() {
  case "$1" in
    unavailable) explanation="The drift check was skipped because kendex is not on PATH." ;;
    failed) explanation="The drift check could not run. Drift status is unknown." ;;
    incomplete) explanation="The drift check is incomplete. Some drift status is unknown." ;;
  esac
  printf 'kendex-drift-%s: %s\n%s\n' "$1" "$2" "$explanation"
}

[ "${KENDEX_DRIFT_HOOK:-}" = "off" ] && exit 0

# The harness hands session metadata on stdin. Read it (guarded — never
# hang a session on a pipe), and skip anything that is not a fresh start:
# a resumed or compacted session already has its context.
input=""
if [ ! -t 0 ]; then
  input=$(cat 2>/dev/null || true)
fi
case "$input" in
  *'"source"'*'"resume"'*) exit 0 ;;
  *'"source"'*'"compact"'*) exit 0 ;;
  *'"source"'*'"reload"'*) exit 0 ;;
esac

if ! command -v kendex >/dev/null 2>&1; then
  notice unavailable "command=kendex"
  exit 0
fi

report=$(kendex check --quiet 2>&1)
code=$?
case "$code" in
  # Clean is silent whatever stderr held: kendex says things there before
  # every command (a leftover from a directory move), and a clean session
  # starts clean.
  0) exit 0 ;;
  1) ;;
  2)
    case "$report" in
      "" | Error:* | error:*) notice failed "exit=$code" ;;
      *) notice incomplete "exit=$code" ;;
    esac
    ;;
  *) notice failed "exit=$code" ;;
esac
if [ -n "$report" ]; then
  printf '%s\n' "$report"
fi
exit 0
"#;

/// The relative catalog location the script installs to.
fn script_path(env: &Env, scope: &Scope) -> std::path::PathBuf {
    crate::source::local_source_root(env, scope)
        .join("hooks")
        .join(format!("{HOOK_NAME}.sh"))
}

/// Whether the scope's installed script is this binary's copy — `None`
/// when the scope does not declare the hook or the script cannot be read.
/// The session check reads this: nothing else ever compares disk to the
/// embedded script, so without it a release that fixes the script would
/// leave every existing install running the old one forever.
pub fn script_current(
    env: &Env,
    scope: &Scope,
    manifest: &crate::manifest::Manifest,
) -> Option<bool> {
    let decl = manifest.hooks.get(HOOK_NAME)?;
    if decl.source != LOCAL_SOURCE_NAME {
        return None;
    }
    let text = crate::fs::read_if_exists(&script_path(env, &scope.canonical())).ok()??;
    Some(text == HOOK_SCRIPT)
}

/// The plan that installs (or repairs) the drift hook declaration in one
/// scope: the script lands in the local source, the manifest declares it
/// for the harnesses that execute hooks natively. Idempotent — a scope
/// already carrying both plans nothing. Rendering into the harness's own
/// directories is the ordinary refresh that follows.
pub fn install_plan(env: &Env, scope: &Scope) -> Result<Plan> {
    let scope = scope.canonical();
    let mut ops = Vec::new();

    let mut manifest = crate::engine::ops::manifest_for_mutation(env, &scope)?;
    let script = script_path(env, &scope);
    let wanted = HOOK_SCRIPT.to_owned();
    let current = crate::fs::read_if_exists(&script)?;
    if current.as_deref() != Some(wanted.as_str()) {
        ops.push(PlannedOp {
            description: "write the drift hook script into the local source".into(),
            op: Op::WriteFile {
                pre: Pre::observed(&script)?,
                path: script,
                bytes: wanted.into_bytes(),
            },
        });
    }

    // A yes to the note is a yes to it running. A declaration switched off
    // from the Library renders nothing and audits clean, so a plan that
    // only declared would leave the switch as it is and report success
    // over a note that never fires.
    let description = match manifest.hooks.get_mut(HOOK_NAME) {
        None => {
            manifest.hooks.insert(
                HOOK_NAME.to_owned(),
                ItemDecl {
                    source: LOCAL_SOURCE_NAME.to_owned(),
                    // Only harnesses that execute hooks: advisory drift prose
                    // on a tool that cannot run the check is worse than none.
                    // Pi executes through the pi-hooks carrier — same script,
                    // same kill-switch, fire-and-forget into session start.
                    harnesses: Some(vec![HarnessId::Claude, HarnessId::Pi]),
                    method: None,
                    rev: None,
                    enabled: true,
                },
            );
            Some("declare the drift hook in kendex.toml")
        }
        Some(decl) if !decl.enabled => {
            decl.enabled = true;
            Some("switch the drift hook back on in kendex.toml")
        }
        Some(_) => None,
    };
    if let Some(description) = description {
        let path = crate::manifest::manifest_path(env, &scope);
        ops.push(PlannedOp {
            description: description.into(),
            op: Op::WriteManifest {
                pre: Pre::observed(&path)?,
                path,
                manifest: Box::new(manifest),
            },
        });
    }

    Plan::landed(scope, ops)
}
