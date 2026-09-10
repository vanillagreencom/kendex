//! The session-start drift hook: first-party content shipped inside kendex
//! itself, never fetched from a catalog — it injects into agent context,
//! and its install must not depend on catalog availability. It is still a
//! declared, user-approved install per scope: the plan writes the script
//! into the scope's local source and declares it like any other hook, so
//! every later refresh, verify, and removal treats it as an ordinary
//! installation.

use crate::apply::{Op, Plan, PlannedOp, Pre, ReadCheck};
use crate::env::Env;
use crate::error::Result;
use crate::manifest::{ItemDecl, LOCAL_SOURCE_NAME, Manifest};
use crate::model::{HarnessId, ItemKind, Scope};

pub const HOOK_NAME: &str = "kendex-drift";

/// The check script as the renderer reads it. Parsed once from the bytes
/// this binary embeds, which are the bytes the install writes.
///
/// `None` where the script does not parse — an invariant of the binary,
/// not of anything on disk. Every reader here fails closed on it: the
/// target list comes out empty, so nothing is declared and no surface
/// claims a tool. [`crate::drift::setup::setup_plan`] says so by name
/// through [`crate::error::CoreError::CheckScriptUnreadable`].
static SCRIPT_SPEC: std::sync::LazyLock<Option<crate::hook::HookSpec>> =
    std::sync::LazyLock::new(|| crate::hook::parse_hook(HOOK_SCRIPT).ok().map(Into::into));

/// The harnesses the check runs in, at a scope of this kind: the ones the
/// script's own frontmatter allows and this build can install hooks to.
///
/// Only tools that execute hooks: advisory drift prose on a tool that
/// cannot run the check is worse than none. Pi executes through the
/// pi-hooks carrier — same script, same kill-switch, fire-and-forget into
/// session start.
///
/// Read off the script rather than written down beside it. The renderer
/// obeys `HookSpec::applies_to` before it places anything
/// ([`crate::engine::desired_kinds`]), so a list stated here as well would
/// be a second list to keep in step by hand — and the surfaces reading it
/// would name a tool the render skips.
pub fn target_harnesses(scope: &Scope) -> Vec<HarnessId> {
    let Some(script) = SCRIPT_SPEC.as_ref() else {
        return Vec::new();
    };
    HarnessId::ALL
        .into_iter()
        .filter(|harness| script.applies_to(*harness))
        .filter(|harness| crate::harness::installs_here(*harness, ItemKind::Hook, scope))
        .collect()
}

/// The same answer for a project, stated once. A scope's kind is the whole
/// of what the filter above reads, so every project on this machine gets
/// this list — which is what lets a surface drawing a card per project ask
/// the question once rather than once per root.
pub fn project_target_harnesses() -> Vec<HarnessId> {
    target_harnesses(&Scope::Project {
        root: std::path::PathBuf::new(),
    })
}

/// What an install of the checks binds to: a project folder that is
/// there. Bound into the plan as well as checked here, so a folder that
/// goes away between the plan and the confirmation that runs it is
/// refused by the apply rather than rebuilt from its parents.
///
/// Read here so a refusal before anything is planned says what is wrong in
/// its own words. The plans themselves carry the same check from
/// [`Plan::landed`], which seeds it for every project scope, so no caller
/// binds it by hand and no plan can be the one that forgot.
///
/// `None` at global scope, which is not a folder a person can move.
pub(crate) fn folder_check(scope: &Scope) -> Option<ReadCheck> {
    match scope {
        Scope::Global => None,
        Scope::Project { root } => Some(ReadCheck::Directory { path: root.clone() }),
    }
}

/// The session-start script. Its header defines the CLI report protocol and
/// the stable keys of notices the hook adds. It never blocks a session.
pub const HOOK_SCRIPT: &str = r#"#!/bin/sh
# ---
# name: kendex-drift
# event: SessionStart
# description: Prints a short drift report at session start, nothing when clean
# summary: Leaves a coding agent a short note at the start of a session saying whether any installed file no longer matches its source. When everything matches, nothing is left.
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
pub(crate) fn script_path(env: &Env, scope: &Scope) -> std::path::PathBuf {
    crate::source::local_source_root(env, scope)
        .join("hooks")
        .join(format!("{HOOK_NAME}.sh"))
}

/// Refuse a scope whose check declaration is not kendex's own.
///
/// The check is declared under one fixed name, so a manifest can carry
/// that name from a marketplace source instead. Nothing downstream tells
/// the two apart: [`declare`] finds the declaration by name and widens and
/// enables it, and the engine then renders whatever source it points at.
/// An action that previewed this binary's script would install and run
/// somebody else's at the start of every coding session.
///
/// Refused rather than reserved, and reported as the collision it is:
/// `engine::ops::add` makes a name already claimed elsewhere a hard error
/// for the same reason (invariant 4), and both read alike.
///
/// The manifest is read here rather than taken from a caller, so each
/// gate judges the file as it stands at its own moment — the preview
/// before it discloses, the plan before it writes.
pub(crate) fn refuse_foreign(env: &Env, scope: &Scope) -> Result<()> {
    let path = crate::manifest::manifest_path(env, scope);
    let crate::manifest::ManifestFile::Current(manifest) = crate::manifest::load(&path)? else {
        return Ok(());
    };
    let Some(decl) = manifest.hooks.get(HOOK_NAME) else {
        return Ok(());
    };
    if decl.source == LOCAL_SOURCE_NAME {
        return Ok(());
    }
    Err(crate::error::CoreError::SourceCollision {
        name: HOOK_NAME.to_owned(),
        existing: crate::engine::ops::source_repo_label(&manifest, &decl.source),
        requested: LOCAL_SOURCE_NAME.to_owned(),
    })
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
    // Before anything is read or written: a registered project whose
    // folder has moved or gone is not a place to install into, and the
    // file writer would make one out of the stale path.
    if let Some(check) = folder_check(&scope) {
        check.check()?;
    }
    // And a declaration under our name that is not ours: widening and
    // enabling it would render a foreign script from this action.
    refuse_foreign(env, &scope)?;
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

    let description = declare(&mut manifest, &scope);
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

/// Put the declaration into a manifest, and say what that changed — the
/// one spelling of "checks are on here", read by the install and by the
/// preview that shows what the install would write.
///
/// A yes to the checks is a yes to them running in every tool the script
/// names. A declaration switched off from the Library renders nothing and
/// audits clean, and one naming fewer tools renders fewer, so a plan that
/// only declared would leave both as they are and report success over a
/// check that never fires, or fires in half the places it promised.
pub(crate) fn declare(manifest: &mut Manifest, scope: &Scope) -> Option<&'static str> {
    let wanted = target_harnesses(scope);
    let Some(decl) = manifest.hooks.get_mut(HOOK_NAME) else {
        manifest.hooks.insert(
            HOOK_NAME.to_owned(),
            ItemDecl {
                source: LOCAL_SOURCE_NAME.to_owned(),
                harnesses: Some(wanted),
                method: None,
                rev: None,
                enabled: true,
            },
        );
        return Some("declare the drift hook in kendex.toml");
    };
    // A narrower list already on the file is not narrowed again by the
    // planner: a declaration that names its harnesses is taken as it
    // stands. Left alone, an enable would report the tools it is about to
    // cover and render fewer, so the list comes up to the set the script
    // runs in — which is what the confirmation lists a file for, tool by
    // tool, before it is pressed.
    let widened = decl.harnesses.as_deref() != Some(wanted.as_slice());
    if widened {
        decl.harnesses = Some(wanted);
    }
    let switched = !decl.enabled;
    decl.enabled = true;
    match (switched, widened) {
        // Re-enabling is the headline where both changed: a declaration
        // switched off renders nothing whatever its list says.
        (true, _) => Some("switch the drift hook back on in kendex.toml"),
        (false, true) => Some("register the drift hook for every tool it runs in, in kendex.toml"),
        (false, false) => None,
    }
}
