//! Catalog CI must render with the binary it installed, not its checkout's
//! authoring rules. Install the same latest release as the workflow, then run
//! its checker against that binary. A checkout build is not release evidence.
#![cfg(unix)]

use std::ffi::OsStr;
use std::fs;
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

use super::{job, run_script, step};
use crate::test_util::{fixture_env, rooted};

#[allow(clippy::unwrap_used)]
fn repo() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .unwrap()
}

#[allow(clippy::unwrap_used)]
fn check(binary: &Path, script: &Path, catalog: &Path, root: &Path) -> Output {
    Command::new("python3")
        .arg(script)
        .arg(binary)
        .arg(catalog)
        .env_clear()
        .env("PATH", std::env::var("PATH").unwrap())
        .env("RUNNER_TEMP", root)
        .output()
        .unwrap()
}

// Only an anonymous release API read may be unavailable on a hosted lane.
// CI supplies GITHUB_TOKEN; an authenticated failure must still fail CI.
fn require_install(install: &Output, token: Option<&OsStr>) -> Result<(), String> {
    if install.status.success() {
        return Ok(());
    }
    let diagnostic = format!(
        "release install status: {}\nstdout:\n{}\nstderr:\n{}",
        install.status,
        String::from_utf8_lossy(&install.stdout),
        String::from_utf8_lossy(&install.stderr),
    );
    if token.is_none()
        && String::from_utf8_lossy(&install.stderr)
            .lines()
            .any(|line| line == "kendex-install: cause=release-read")
    {
        return Err(format!(
            "anonymous GitHub release read unavailable; GITHUB_TOKEN is unset\n{diagnostic}"
        ));
    }
    panic!("{diagnostic}");
}

#[test]
#[allow(clippy::unwrap_used)]
fn install_failures_keep_both_streams_and_only_anonymous_release_reads_skip() {
    // This holds the test's handling of the installer's report protocol, not
    // shipped behavior. Dropping either stream from require_install makes
    // the failure assertion red; accepting installer-run makes it red too.
    for (cause, token) in [
        ("release-read", None),
        ("release-read", Some(OsStr::new("read-only"))),
        ("installer-run", None),
    ] {
        let output = Command::new("/bin/sh")
            .args([
                "-c",
                "printf 'installer-stdout'; printf 'kendex-install: cause=%s\\ninstaller-stderr' \"$1\" >&2; exit 1",
                "installer-fixture",
                cause,
            ])
            .env_clear()
            .output()
            .unwrap();
        let result = std::panic::catch_unwind(|| require_install(&output, token));
        let diagnostic = if cause == "release-read" && token.is_none() {
            result.unwrap().unwrap_err()
        } else {
            *result.unwrap_err().downcast::<String>().unwrap()
        };
        assert!(diagnostic.contains("exit status: 1"), "{diagnostic}");
        assert!(diagnostic.contains("installer-stdout"), "{diagnostic}");
        assert!(diagnostic.contains("installer-stderr"), "{diagnostic}");
    }
}

#[allow(clippy::unwrap_used)]
fn ignored_catalog_keeps_its_own_ignore_rules(
    binary: &Path,
    script: &Path,
    root: &Path,
    home: &Path,
    text: &str,
) {
    // Hosted snapshots can live under an enclosing checkout's ignored tmp/.
    // Model that layout without changing this checkout or its ignore rules.
    let ignored = root.join("ignored");
    let catalog = ignored.join("catalog");
    fs::create_dir_all(catalog.join("agents")).unwrap();
    fs::write(root.join(".gitignore"), "ignored/\n").unwrap();
    fs::write(catalog.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
    fs::write(
        catalog.join("agents/planner.md"),
        "---\nname: planner\ndescription: Write a plan\ntracked-outputs: [docs/plans/<slug>.md]\n---\nWrite a plan.\n",
    )
    .unwrap();
    for directory in [root, catalog.as_path()] {
        if directory == catalog.as_path() {
            fs::write(catalog.join(".gitignore"), "docs/plans/\n").unwrap();
        }
        let init = Command::new("git")
            .args(["init", "--quiet"])
            .current_dir(directory)
            .env_clear()
            .envs(fixture_env(home))
            .env("PATH", std::env::var("PATH").unwrap())
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .output()
            .unwrap();
        assert!(init.status.success(), "{init:?}");
        let output = check(binary, script, &catalog, &ignored);
        if directory == root {
            assert!(output.status.success(), "ignored snapshot: {output:?}");
            let target = "        ceilings = os.pathsep.join((*(str(path.parent) for path in catalogs), str(root)))\n";
            assert_eq!(text.matches(target).count(), 1);
            let mutated = text.replace(target, "        ceilings = \"\"\n");
            assert_ne!(text, mutated);
            let mutant = root.join("unbounded-git.py");
            fs::write(&mutant, mutated).unwrap();
            let output = check(binary, &mutant, &catalog, &ignored);
            assert_eq!(output.status.code(), Some(1), "{output:?}");
            assert!(
                String::from_utf8_lossy(&output.stdout).contains("tracked-output"),
                "{output:?}"
            );
        } else {
            // The catalog's own ignore policy is real authoring input.
            assert_eq!(output.status.code(), Some(1), "{output:?}");
            assert!(
                String::from_utf8_lossy(&output.stdout).contains("docs/plans/"),
                "{output:?}"
            );
        }
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn the_current_catalog_renders_and_incomplete_delivery_fails() {
    let tmp = tempfile::tempdir().unwrap();
    let root = rooted(&tmp);
    let repository = repo();
    let script = repository.join("tools/catalog-release-check");
    let home = root.join("release-home");
    fs::create_dir(&home).unwrap();
    let mut installer = Command::new("/bin/bash");
    installer
        .arg(repository.join("skills/review-gate/scripts/install-latest.sh"))
        .current_dir(&root)
        .env_clear()
        .env("PATH", std::env::var("PATH").unwrap())
        .envs(fixture_env(&home));
    // CI supplies its read-only API token. No other caller credentials enter
    // this isolated process, and the helper clears the token before install.
    let token = std::env::var_os("GITHUB_TOKEN").filter(|token| !token.is_empty());
    if let Some(token) = &token {
        installer.env("GITHUB_TOKEN", token);
    }
    let install = installer.output().unwrap();
    if let Err(reason) = require_install(&install, token.as_deref()) {
        // Bypass libtest's capture so a successful-but-skipped network test
        // reports its reason even in the full validation's quiet run.
        writeln!(std::io::stderr(), "catalog-release: skip={reason}").unwrap();
        return;
    }
    eprintln!("{}", String::from_utf8_lossy(&install.stdout));
    let binary = home.join(".local/bin/kendex");
    let output = check(&binary, &script, &repository, &root);
    eprintln!(
        "current catalog: {}",
        String::from_utf8_lossy(&output.stdout)
    );
    assert!(output.status.success(), "{output:?}");
    let record = String::from_utf8(output.stdout).unwrap();
    assert!(record.starts_with("catalog-release: version="), "{record}");
    assert!(record.contains(" result=pass"), "{record}");

    let text = fs::read_to_string(&script).unwrap();
    ignored_catalog_keeps_its_own_ignore_rules(&binary, &script, &root, &home, &text);

    // Both declarations parse. Core's catalog check must refuse delivery
    // to the named unsupported harness before the wrapper installs anything.
    let manifest = "is_source_catalog = true\n";
    for (name, event, harnesses, expected_feature, control) in [
        (
            "permission-request",
            "PermissionRequest",
            "claude, gemini",
            "kendex-hook-unsupported: harness=gemini event=PermissionRequest hook=future",
            Some((
                "if rendered.returncode != 0:",
                "if False and rendered.returncode != 0:",
            )),
        ),
        (
            "stop-failure",
            "StopFailure",
            "claude, codex",
            "kendex-hook-unsupported: harness=codex event=StopFailure hook=future",
            None,
        ),
    ] {
        let catalog = root.join(name);
        fs::create_dir_all(catalog.join("hooks")).unwrap();
        fs::write(catalog.join("kendex.toml"), manifest).unwrap();
        fs::write(catalog.join("hooks/future.sh"), format!(
            "#!/bin/sh\n# ---\n# name: future\n# event: {event}\n# description: Check requests\n# harnesses: [{harnesses}]\n# ---\nexit 0\n")).unwrap();
        let rejects = |output: &Output| {
            let record = String::from_utf8_lossy(&output.stdout);
            output.status.code() == Some(1)
                && record.starts_with("catalog-release: version=")
                && record.lines().next().unwrap().contains("feature=")
                && record.lines().next().unwrap().contains(expected_feature)
        };
        let output = check(&binary, &script, &catalog, &root);
        eprintln!("{name}: {}", String::from_utf8_lossy(&output.stdout));
        assert!(rejects(&output), "{name}: {output:?}");
        assert_eq!(
            fs::read_to_string(catalog.join("kendex.toml")).unwrap(),
            manifest,
            "the checker must not change its input"
        );

        if let Some((target, replacement)) = control {
            // Keep the commands and diagnostic, but disable the refusal.
            // The same rejection assertion must then fail.
            assert_eq!(text.matches(target).count(), 1);
            let mutated = text.replace(target, replacement);
            assert_ne!(text, mutated);
            let mutant = root.join(format!("inert-{name}.py"));
            fs::write(&mutant, mutated).unwrap();
            let output = check(&binary, &mutant, &catalog, &root);
            assert!(
                output.status.success(),
                "control must reach the incorrect pass: {output:?}"
            );
            assert!(String::from_utf8_lossy(&output.stdout).contains(" result=pass"));
            assert!(
                !rejects(&output),
                "control escaped the rejection assertion: {output:?}"
            );
        }
    }
}

const RENDER_COMMAND: &str = "python3 kendex/tools/catalog-release-check \"$HOME/.local/bin/kendex\" \"$CATALOG_PATH\" ${{ !inputs.strict && '--allow-advisories' || '' }} ${PRIOR_PATH:+--prior \"$PRIOR_PATH\"}";

/// What the prior-catalog steps hand the checker, each run as bash runs
/// them: the base commit the caller's event names, or a `catalog-release:
/// upgrade=skip cause=` line and no `--prior`.
#[allow(clippy::unwrap_used)]
fn assert_prior_selection(workflow: &str) {
    let find = step(workflow, "name: Find the prior catalog");
    assert!(find.iter().any(|line| line.trim()
        == "PRIOR_SHA: ${{ github.event.pull_request.base.sha || github.event.merge_group.base_sha || github.event.before }}"));
    let sha = "0123456789abcdef0123456789abcdef01234567";
    let zeros = "0".repeat(40);
    for (prior, chosen, said) in [
        (sha, Some(sha), None),
        (zeros.as_str(), None, Some("no-prior-commit")),
        ("", None, Some("no-base-commit")),
    ] {
        let tmp = tempfile::tempdir().unwrap();
        let output = rooted(&tmp).join("github-output");
        let run = Command::new("bash")
            .args(["-e", "-c", &run_script(&find)])
            .env_clear()
            .env("PATH", std::env::var("PATH").unwrap())
            .env("PRIOR_SHA", prior)
            .env("GITHUB_OUTPUT", &output)
            .output()
            .unwrap();
        assert!(run.status.success(), "{prior}: {run:?}");
        let written = fs::read_to_string(&output).unwrap_or_default();
        assert_eq!(
            written.lines().find_map(|line| line.strip_prefix("sha=")),
            chosen,
            "{prior}: {written}"
        );
        let skipped = String::from_utf8_lossy(&run.stdout)
            .lines()
            .find_map(|line| line.strip_prefix("catalog-release: upgrade=skip cause="))
            .map(str::to_owned);
        assert_eq!(skipped.as_deref(), said, "{prior}: {run:?}");
    }

    // A stand-in python3 prints the checker's arguments, one per line.
    let render = run_script(&step(
        workflow,
        "name: Render the catalog with the released engine",
    ))
    .replace("${{ !inputs.strict && '--allow-advisories' || '' }}", "");
    let tmp = tempfile::tempdir().unwrap();
    let root = rooted(&tmp);
    let root = root.as_path();
    let bin = root.join("bin");
    fs::create_dir_all(&bin).unwrap();
    fs::create_dir_all(root.join("prior/present")).unwrap();
    let python = bin.join("python3");
    fs::write(&python, "#!/bin/sh\nprintf 'arg=%s\\n' \"$@\"\n").unwrap();
    fs::set_permissions(&python, fs::Permissions::from_mode(0o755)).unwrap();
    for (prior, handed, said) in [
        ("", None, None),
        ("prior/present", Some("prior/present"), None),
        ("prior/absent", None, Some("path-absent")),
    ] {
        let run = Command::new("bash")
            .args(["-e", "-c", &render])
            .current_dir(root)
            .env_clear()
            .env(
                "PATH",
                format!("{}:{}", bin.display(), std::env::var("PATH").unwrap()),
            )
            .envs(fixture_env(root))
            .env("CATALOG_PATH", "catalog/.")
            .env("PRIOR_PATH", prior)
            .output()
            .unwrap();
        assert!(run.status.success(), "{prior}: {run:?}");
        let stdout = String::from_utf8_lossy(&run.stdout);
        let arguments: Vec<_> = stdout
            .lines()
            .filter_map(|line| line.strip_prefix("arg="))
            .collect();
        let binary = format!("{}/.local/bin/kendex", root.display());
        let mut expected = vec!["kendex/tools/catalog-release-check", &binary, "catalog/."];
        if let Some(path) = handed {
            expected.extend(["--prior", path]);
        }
        assert_eq!(arguments, expected, "{prior}: {stdout}");
        let skipped = stdout
            .lines()
            .find_map(|line| line.strip_prefix("catalog-release: upgrade=skip cause="))
            .map(|rest| rest.split_whitespace().next().unwrap_or_default());
        assert_eq!(skipped, said, "{prior}: {stdout}");
    }
}

/// The caller's base commit reaches the checker as `--prior`, and each case
/// with no prior catalog skips by name. Controls: an all-zero `before` taken
/// as a commit, and a base without the catalog path handed on, each fail the
/// assertion.
#[test]
#[allow(clippy::unwrap_used)]
fn catalog_ci_hands_the_callers_base_catalog_to_the_upgrade_leg() {
    let text = fs::read_to_string(repo().join(".github/workflows/catalog-check.yml")).unwrap();
    assert_prior_selection(&text);
    for (target, replacement) in [
        ("            *[!0]*) echo", "            *) echo"),
        (
            "if [ -n \"$PRIOR_PATH\" ] && [ ! -d \"$PRIOR_PATH\" ]; then",
            "if false; then",
        ),
    ] {
        assert_eq!(text.matches(target).count(), 1, "{target}");
        let mutated = text.replace(target, replacement);
        assert_ne!(text, mutated);
        assert!(
            std::panic::catch_unwind(|| assert_prior_selection(&mutated)).is_err(),
            "{target}"
        );
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn catalog_ci_installs_the_release_and_runs_its_render_check() {
    let text = fs::read_to_string(repo().join(".github/workflows/catalog-check.yml")).unwrap();
    let assert_install_scope = |workflow: &str| {
        let install_step = step(workflow, "name: Install latest released kendex");
        assert_eq!(
            run_script(&install_step).trim(),
            "kendex/skills/review-gate/scripts/install-latest.sh"
        );
        let environment: Vec<_> = install_step
            .iter()
            .skip_while(|line| line.trim() != "env:")
            .skip(1)
            .take_while(|line| line.starts_with("          "))
            .map(|line| line.trim())
            .collect();
        assert_eq!(
            environment,
            ["GH_TOKEN: \"\"", "GITHUB_TOKEN: ${{ github.token }}"]
        );
        assert_eq!(workflow.matches("${{ github.token }}").count(), 1);
        assert_eq!(workflow.matches("GITHUB_TOKEN:").count(), 1);
        let check_job = job(workflow, "check");
        let permissions: Vec<_> = check_job
            .iter()
            .take_while(|line| line.trim() != "steps:")
            .skip_while(|line| line.trim() != "permissions:")
            .skip(1)
            .take_while(|line| line.starts_with("      "))
            .map(|line| line.trim())
            .collect();
        assert_eq!(permissions, ["contents: read"]);
    };
    assert_install_scope(&text);
    for (target, replacement) in [
        ("      contents: read", "      contents: write"),
        (
            "          GH_TOKEN: \"\"",
            "          GH_TOKEN: ${{ github.token }}",
        ),
        ("          GITHUB_TOKEN: ${{ github.token }}\n", ""),
        (
            "          GITHUB_TOKEN: ${{ github.token }}",
            "          GITHUB_TOKEN: ${{ steps.token.outputs.token }}",
        ),
        (
            "      - name: Render the catalog with the released engine\n        env:\n",
            "      - name: Render the catalog with the released engine\n        env:\n          GITHUB_TOKEN: ${{ github.token }}\n",
        ),
    ] {
        assert_eq!(text.matches(target).count(), 1);
        let mutated = text.replace(target, replacement);
        assert_ne!(text, mutated);
        assert!(std::panic::catch_unwind(|| assert_install_scope(&mutated)).is_err());
    }
    let assert_blocking_render = |workflow: &str| {
        let render_step = step(
            workflow,
            "name: Render the catalog with the released engine",
        );
        // GitHub defaults continue-on-error to false. With the checker as
        // the last shell command, a nonzero exit must fail this step.
        assert!(
            !render_step
                .iter()
                .any(|line| line.trim_start().starts_with("continue-on-error:")),
            "released-engine render must block catalog CI"
        );
        assert_eq!(
            run_script(&render_step).trim().lines().last(),
            Some(RENDER_COMMAND)
        );
    };
    assert_blocking_render(&text);

    // Keep the command but suppress its blocking effect. The same assertion
    // must reject the workflow that GitHub would accept after a failed render.
    let target = "      - name: Render the catalog with the released engine\n";
    assert_eq!(text.matches(target).count(), 1);
    let mutated = text.replace(
        target,
        &format!("{target}        continue-on-error: true\n"),
    );
    assert_ne!(text, mutated);
    assert!(std::panic::catch_unwind(|| assert_blocking_render(&mutated)).is_err());
    assert!(!text.contains("cargo build"));
    assert!(!text.contains("target/release/kendex"));
}
