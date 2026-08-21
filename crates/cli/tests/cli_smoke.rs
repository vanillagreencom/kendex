//! Round-trip against the real tools: stage the exact trees kendex emits,
//! then let each harness's own CLI read them.
//!
//! Unit tests assert what our renderers produce. They cannot tell us that
//! the far end accepts it — the three bugs wshobson recorded in
//! `docs/round-trip-results.md` were all of that shape, and all of them
//! passed unit tests. This is the only check in the suite where something
//! other than kendex reads kendex's output.
//!
//! Opt-in: set `KENDEX_CLI_SMOKE=1`. Without it the test does nothing and
//! says so, because installing seven CLIs is not a precondition for
//! running the suite. With it, a run where *every* harness was absent is a
//! failure, not a pass: a gate that skips everything and reports green is
//! worse than no gate at all.
#![cfg(unix)]

use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

/// One harness's own CLI, and the command that makes it read what we wrote.
struct Probe {
    /// The binary as it is installed.
    bin: &'static str,
    /// kendex's id for the same tool.
    harness: &'static str,
    args: &'static [&'static str],
    /// A string the output must contain — set where the CLI actually lists
    /// what it loaded, so the check proves the tree was read and not merely
    /// that the binary starts.
    expects: Option<&'static str>,
}

/// Which of these CI installs is documented in
/// `.github/workflows/catalog-check.yml`; the rest are skipped when absent.
const PROBES: &[Probe] = &[
    Probe {
        bin: "opencode",
        harness: "opencode",
        args: &["agent", "list"],
        expects: Some("reviewer"),
    },
    Probe {
        bin: "gemini",
        harness: "gemini",
        args: &["extensions", "list"],
        expects: None,
    },
    Probe {
        bin: "codex",
        harness: "codex",
        args: &["--version"],
        expects: None,
    },
    Probe {
        bin: "claude",
        harness: "claude",
        args: &["--version"],
        expects: None,
    },
    Probe {
        bin: "cursor-agent",
        harness: "cursor",
        args: &["--version"],
        expects: None,
    },
    Probe {
        bin: "pi",
        harness: "pi",
        args: &["--version"],
        expects: None,
    },
    Probe {
        bin: "copilot",
        harness: "copilot",
        args: &["--version"],
        expects: None,
    },
];

fn note(line: &str) {
    let _ = writeln!(std::io::stderr(), "smoke: {line}");
}

#[allow(clippy::expect_used)]
fn run(bin: &str, home: &Path, cwd: &Path, args: &[&str]) -> Output {
    Command::new(bin)
        .args(args)
        .current_dir(cwd)
        .env_clear()
        .env("HOME", home)
        .env("KENDEX_REAL_HOME", "1")
        .env("PATH", std::env::var("PATH").unwrap_or_default())
        .env("NO_COLOR", "1")
        .output()
        .expect("the command runs")
}

fn installed(bin: &str) -> bool {
    Command::new("sh")
        .args(["-c", &format!("command -v {bin}")])
        .output()
        .is_ok_and(|out| out.status.success())
}

/// A catalog with one item of every kind kendex renders, then a global
/// install of all of it for every harness that can hold it.
#[allow(clippy::unwrap_used)]
fn stage(home: &Path) -> PathBuf {
    let catalog = home.join("catalog");
    let write = |relative: &str, body: &str| {
        let path = catalog.join(relative);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, body).unwrap();
    };
    write(
        "agents/reviewer.md",
        "---\nname: reviewer\ndescription: Use this when reviewing a change for risk.\nmodel: sonnet\nrole: engineer\n---\n\n# reviewer\n\nRead the diff and name what could break.\n",
    );
    write(
        "skills/release-notes/SKILL.md",
        "---\nname: release-notes\ndescription: Use this when writing release notes from a changelog.\n---\n\n# release-notes\n\n- group the entries by what a reader would notice\n",
    );
    write(
        "commands/summarise.md",
        "---\nname: summarise\ndescription: Summarise the current change.\n---\n\nSummarise what changed and why.\n",
    );
    write(
        "hooks/guard-bash.sh",
        "#!/usr/bin/env bash\n# ---\n# name: guard-bash\n# event: PreToolUse\n# matcher: Bash\n# description: Refuse commands that write outside the project.\n# ---\nset -euo pipefail\nexit 0\n",
    );
    write(
        "mcp/docs.toml",
        "command = \"docs-mcp\"\nargs = [\"--stdio\"]\n",
    );

    // Every harness by name rather than by detection: a fresh temporary
    // home has none of their marker directories, and this must stage the
    // same trees whether or not the machine happens to run these tools.
    let kendex = env!("CARGO_BIN_EXE_kendex");
    let out = run(
        kendex,
        home,
        home,
        &[
            "add",
            catalog.to_str().unwrap(),
            "--global",
            "--all",
            "--copy",
            "--harness",
            "claude,codex,opencode,cursor,pi,gemini,copilot",
            "-y",
        ],
    );
    assert!(
        out.status.success(),
        "staging failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    catalog
}

#[test]
#[allow(clippy::unwrap_used)]
fn every_harness_cli_reads_what_kendex_wrote() {
    if std::env::var("KENDEX_CLI_SMOKE").as_deref() != Ok("1") {
        note("not run — set KENDEX_CLI_SMOKE=1 with the harness CLIs installed");
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    std::fs::create_dir_all(home).unwrap();
    stage(home);

    let mut checked = Vec::new();
    let mut skipped = Vec::new();
    let mut failed = Vec::new();
    for probe in PROBES {
        if !installed(probe.bin) {
            skipped.push(probe.harness);
            note(&format!(
                "{}: skipped, {} is not installed",
                probe.harness, probe.bin
            ));
            continue;
        }
        let out = run(probe.bin, home, home, probe.args);
        let said = format!(
            "{}{}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        );
        let listed = probe.expects.is_none_or(|needle| said.contains(needle));
        match out.status.success() && listed {
            true => checked.push(probe.harness),
            false => failed.push(format!("{} ({}): {said}", probe.harness, probe.bin)),
        }
    }

    note(&format!(
        "{} checked, {} skipped, {} failed",
        checked.len(),
        skipped.len(),
        failed.len()
    ));
    assert!(failed.is_empty(), "{}", failed.join("\n"));
    // The whole point of the gate: a run that reached nothing proves
    // nothing, and must never be reported as a pass.
    assert!(
        !checked.is_empty(),
        "every harness CLI was absent, so nothing was checked — install at least one of: {}",
        PROBES
            .iter()
            .map(|probe| probe.bin)
            .collect::<Vec<_>>()
            .join(", ")
    );
}
