//! rust-fmt, rust-clippy and biome — the commit-time lint lanes over
//! staged source, so a hook install through the githooks module carries
//! the format and lint gate with it. The staged list is read from the
//! index like every guard read; the lint itself runs the project's
//! toolchain over the working tree — the trade-off a whole-file committer
//! accepts. Tools are resolved by well-known name (cargo, biome) or from
//! the project's own untracked `node_modules/.bin`; a committed file
//! never names the command to run.

use std::path::{Path, PathBuf};
use std::time::Duration;

use crate::error::Result;
use crate::process::Hardened;

use super::{GuardCtx, Outcome, guard_err};

/// Room for a cold clippy build. fmt and biome share it rather than each
/// inventing a budget; they finish in seconds and only a wedged tool ever
/// meets the ceiling.
const LINT_TIMEOUT: Duration = Duration::from_secs(600);

/// How much of a failed tool's output travels into the report — enough to
/// act on, bounded so one pathological run cannot flood the verdict.
const OUTPUT_TAIL_LINES: usize = 40;

/// Staged paths, deletions excluded, keeping those with one of
/// `extensions`. NUL-delimited so no path shape can garble the list.
fn staged_with_extension(ctx: &GuardCtx, check: &str, extensions: &[&str]) -> Result<Vec<String>> {
    let raw = ctx.git_ok(
        check,
        &["diff", "--cached", "--name-only", "-z", "--diff-filter=d"],
    )?;
    let mut files = Vec::new();
    for path in raw.split(|byte| *byte == 0).filter(|path| !path.is_empty()) {
        let Ok(path) = std::str::from_utf8(path) else {
            return Err(guard_err(
                check,
                format!(
                    "staged path is not valid UTF-8: {:?}",
                    String::from_utf8_lossy(path)
                ),
            ));
        };
        let extension = Path::new(path).extension().and_then(|ext| ext.to_str());
        if extension.is_some_and(|ext| extensions.contains(&ext)) {
            files.push(path.to_owned());
        }
    }
    Ok(files)
}

/// A failed tool run's evidence, folded into the report: the tail of its
/// combined output, then the violation line.
fn fail_with_output(out: &mut Outcome, output: &std::process::Output, line: String, remedy: &str) {
    let combined = format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let lines: Vec<&str> = combined.lines().collect();
    let start = lines.len().saturating_sub(OUTPUT_TAIL_LINES);
    for shown in &lines[start..] {
        out.say(*shown);
    }
    out.violation(line, remedy);
}

/// The manifests owning the staged Rust files: for each file, the walk up
/// from its directory stops at the first `Cargo.toml`, which owns the file
/// only when it carries a `[package]` table — a virtual workspace manifest
/// has no default package to scope a cargo invocation to. Per-manifest
/// scoping keeps crates excluded from the root workspace lintable and
/// keeps unrelated members' pre-existing warnings from blocking the
/// commit. A manifest that exists but cannot be read is a refusal, never
/// an absent owner.
fn owning_manifests(ctx: &GuardCtx, check: &str, files: &[String]) -> Result<Vec<PathBuf>> {
    let mut manifests = std::collections::BTreeSet::new();
    for file in files {
        let mut dir = Path::new(file).parent();
        while let Some(current) = dir {
            let candidate = ctx.root.join(current).join("Cargo.toml");
            if candidate.exists() {
                let text = std::fs::read_to_string(&candidate).map_err(|e| {
                    guard_err(check, format!("cannot read {}: {e}", candidate.display()))
                })?;
                let has_package = text
                    .lines()
                    .any(|line| line.split('#').next().unwrap_or_default().trim() == "[package]");
                if has_package {
                    manifests.insert(candidate);
                }
                break;
            }
            dir = current.parent();
        }
    }
    Ok(manifests.into_iter().collect())
}

/// One cargo lane invocation from the repository root; the caller judges
/// the exit status.
fn cargo(ctx: &GuardCtx, args: &[&str]) -> Hardened {
    Hardened::lint_tool(Path::new("cargo"), args, &ctx.root).timeout(LINT_TIMEOUT)
}

/// Which exit statuses a lane reads as findings rather than as a tool
/// that could not run. `cargo fmt --check` separates the two: 1 is diffs,
/// anything else is breakage. cargo folds clippy's denied warnings and a
/// broken build into one status, so for clippy every failure reports as
/// the violation with the tool's own output as the evidence.
enum FailureReads {
    ExitOneOnly,
    AnyFailure,
}

/// rust-fmt — staged `.rs` files must be formatted.
pub fn run_fmt(ctx: &GuardCtx) -> Result<Outcome> {
    const CHECK: &str = "rust-fmt";
    rust_lane(ctx, CHECK, FailureReads::ExitOneOnly, |manifest| {
        let mut args = vec!["fmt"];
        if let Some(path) = manifest {
            args.extend(["--manifest-path", path]);
        }
        args.push("--check");
        args
    })
}

/// rust-clippy — staged `.rs` files lint clean under `-D warnings`,
/// scoped per owning manifest.
pub fn run_clippy(ctx: &GuardCtx) -> Result<Outcome> {
    const CHECK: &str = "rust-clippy";
    rust_lane(ctx, CHECK, FailureReads::AnyFailure, |manifest| {
        let mut args = vec!["clippy"];
        match manifest {
            Some(path) => args.extend(["--manifest-path", path]),
            None => args.push("--workspace"),
        }
        args.extend(["--all-targets", "--", "-D", "warnings"]);
        args
    })
}

/// The shared shape of both Rust lanes: resolve scope from the staged
/// set, run cargo once per owning manifest (or once from the root when no
/// manifest owns the files but the root carries one), fold failures.
fn rust_lane(
    ctx: &GuardCtx,
    check: &str,
    failures: FailureReads,
    lane_args: impl Fn(Option<&str>) -> Vec<&str>,
) -> Result<Outcome> {
    let mut out = Outcome::default();
    let files = staged_with_extension(ctx, check, &["rs"])?;
    if files.is_empty() {
        out.say(format!("{check}: OK — no staged Rust files"));
        return Ok(out);
    }
    let manifests = owning_manifests(ctx, check, &files)?;
    let scopes: Vec<Option<String>> = match manifests.is_empty() {
        false => manifests
            .iter()
            .map(|path| Some(path.display().to_string()))
            .collect(),
        true if ctx.root.join("Cargo.toml").exists() => vec![None],
        // Staged Rust outside any cargo project — fixtures, scripts —
        // has no toolchain to answer for it; silence would be a lie, so
        // the skip says itself out loud.
        true => {
            out.say(format!(
                "{check}: no Cargo.toml owns the staged .rs files — skipped"
            ));
            return Ok(out);
        }
    };
    for scope in &scopes {
        let args = lane_args(scope.as_deref());
        let invocation = format!("cargo {}", args.join(" "));
        let output = cargo(ctx, &args).run()?;
        let finding = match (output.status.code(), &failures) {
            (Some(0), _) => false,
            (Some(1), _) | (_, FailureReads::AnyFailure) => true,
            _ => {
                return Err(guard_err(
                    check,
                    format!(
                        "{invocation} could not run: {}",
                        String::from_utf8_lossy(&output.stderr).trim()
                    ),
                ));
            }
        };
        if finding {
            fail_with_output(
                &mut out,
                &output,
                format!("{check} FAIL: {invocation}"),
                &remedy(check),
            );
        }
    }
    if out.violations == 0 {
        out.say(format!(
            "{check}: OK — {} staged Rust file(s), {} lane run(s)",
            files.len(),
            scopes.len()
        ));
    }
    Ok(out)
}

fn remedy(check: &str) -> String {
    match check {
        "rust-fmt" => "run cargo fmt and restage".to_owned(),
        _ => "fix the reported warnings before committing".to_owned(),
    }
}

/// biome — staged JS/TS/JSON files in a Biome project lint clean. The
/// project's own pinned binary outranks PATH; a Biome project with no
/// binary anywhere is a visible skip, not a silent pass — installing
/// dependencies is a machine-local act this guard cannot take. Absence is
/// settled before the spawn and nowhere else: once a binary is chosen,
/// every way it can fail to run blocks, including the ENOENT a launcher
/// with a missing `#!` interpreter raises — the same errno a missing
/// binary gives, which is why the spawn error must not be the judge. The
/// `--no-errors-on-unmatched` flag keeps a commit that stages only
/// ignored paths committable: those files are ignored precisely because
/// they must not be linted.
pub fn run_biome(ctx: &GuardCtx) -> Result<Outcome> {
    const CHECK: &str = "biome";
    let mut out = Outcome::default();
    let staged = staged_with_extension(
        ctx,
        CHECK,
        &["ts", "tsx", "js", "jsx", "mjs", "cjs", "json", "jsonc"],
    )?;
    if staged.is_empty() {
        out.say("biome: OK — no staged Biome-checkable files");
        return Ok(out);
    }
    if !ctx.root.join("biome.json").exists() && !ctx.root.join("biome.jsonc").exists() {
        out.say("biome: OK — not a Biome project");
        return Ok(out);
    }
    let Some(binary) = biome_binary(&ctx.root) else {
        out.say("biome: biome.json present but no biome binary found, pinned or on PATH — skipped");
        return Ok(out);
    };
    // Only staged paths that still exist on disk: the lane lints the
    // working tree, and a path renamed away since staging has nothing
    // there to lint. Staged paths are repo-relative and git lets them
    // start with `-`; the `./` keeps each one a path operand rather than
    // an option biome would honor (`--config-path=…` would repoint the
    // lint at a config of the commit's choosing).
    let files: Vec<String> = staged
        .iter()
        .filter(|path| ctx.root.join(path).is_file())
        .map(|path| format!("./{path}"))
        .collect();
    if files.is_empty() {
        out.say("biome: OK — no staged Biome-checkable files on disk");
        return Ok(out);
    }
    let mut args = vec!["check", "--no-errors-on-unmatched"];
    args.extend(files.iter().map(String::as_str));
    let output = Hardened::lint_tool(&binary, &args, &ctx.root)
        .timeout(LINT_TIMEOUT)
        .run()
        .map_err(|error| {
            guard_err(
                CHECK,
                format!("{} could not run: {error}", binary.display()),
            )
        })?;
    match output.status.code() {
        Some(0) => out.say(format!(
            "biome: OK — {} staged file(s) checked",
            files.len()
        )),
        // 126 and 127 are the launcher's verdicts — interpreter or
        // command missing — never biome's findings.
        Some(126 | 127) => {
            return Err(guard_err(
                CHECK,
                format!(
                    "{} could not run: {}",
                    binary.display(),
                    String::from_utf8_lossy(&output.stderr).trim()
                ),
            ));
        }
        _ => fail_with_output(
            &mut out,
            &output,
            "biome FAIL: biome check on staged files".to_owned(),
            "run biome check --write and restage",
        ),
    }
    Ok(out)
}

/// The project's pinned biome when it is executable, else the first
/// executable `biome` on PATH — the same PATH the child inherits — else
/// nothing.
fn biome_binary(root: &Path) -> Option<PathBuf> {
    let pinned = root.join("node_modules/.bin/biome");
    if is_executable(&pinned) {
        return Some(pinned);
    }
    std::env::var_os("PATH").and_then(|paths| {
        std::env::split_paths(&paths)
            .map(|dir| dir.join("biome"))
            .find(|candidate| is_executable(candidate))
    })
}

fn is_executable(path: &Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        path.metadata()
            .map(|meta| meta.is_file() && meta.permissions().mode() & 0o111 != 0)
            .unwrap_or(false)
    }
    #[cfg(not(unix))]
    {
        path.is_file()
    }
}
