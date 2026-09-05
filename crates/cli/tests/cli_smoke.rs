//! Round-trip against the real tools: stage the exact trees kendex emits,
//! then let each harness's own CLI read them.
//!
//! Unit tests assert what our renderers produce. They cannot tell us that
//! the far end accepts it: green unit tests over a render the harness
//! throws away is the failure they cannot see. This is the only check in
//! the suite where something other than kendex reads kendex's output.
//!
//! A probe is a command that *loads* the rendered tree and answers with
//! what it loaded or what it rejected. `--version` is not one: starting a
//! binary says nothing about files it never opens, so unreadable
//! `.codex/agents/*.toml` files ship behind a green `codex --version`. A
//! harness that ships no such command is named as uncovered, with the
//! reason — never counted as checked.
//!
//! Opt-in: set `KENDEX_CLI_SMOKE=1`. Without it the test does nothing and
//! says so, because installing seven CLIs is not a precondition for
//! running the suite. With it, a run where *every* harness was absent is a
//! failure, not a pass: a gate that skips everything and reports green is
//! worse than no gate at all.
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;

use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

/// What a harness's CLI said, kept apart because the two streams answer
/// different questions: `codex doctor` prints its report on stdout and
/// exits non-zero for the unrelated reason that a staged home has no
/// credentials, so its verdict reads stdout and ignores the status.
struct Said {
    out: String,
    err: String,
    ok: bool,
}

impl Said {
    fn all(&self) -> String {
        format!("{}{}", self.out, self.err)
    }
}

/// The command that makes one harness read what kendex wrote, and how to
/// tell from its answer that it did.
struct Reader {
    args: &'static [&'static str],
    /// Rendered files this command loads, relative to the staged home.
    /// Asserted present before the probe runs: a staging that stopped
    /// emitting one of them would otherwise pass the probe vacuously.
    loads: &'static [&'static str],
    /// `Ok` when the CLI says it loaded what we wrote.
    verdict: fn(&Said) -> Result<(), String>,
    /// The rejected renders the must-fail control writes — one per way
    /// this verdict can go red, so no branch of it is only asserted in
    /// the direction that passes.
    rejects: &'static [Reject],
}

/// A render this harness is known to refuse, so the control can watch the
/// probe go red on one.
struct Reject {
    /// Relative to the staged home; one of the reader's `loads`.
    file: &'static str,
    /// Rewrites that file into one the harness rejects.
    spoil: fn(&str) -> String,
    /// What `spoil` leaves behind. The control asserts this is really in
    /// the file before it asserts the CLI rejected it, so a spoiler that
    /// quietly stopped applying cannot read as a rejection.
    marker: &'static str,
}

enum Reads {
    /// This harness's own CLI loads the rendered tree and reports on it.
    Cli(Reader),
    /// Nothing this CLI ships reads the rendered tree without an
    /// authenticated session. Recorded so the gap is reported by name.
    NothingOffline(&'static str),
}

/// One harness, and whether anything it ships can read kendex's output.
struct Probe {
    /// The binary as it is installed.
    bin: &'static str,
    /// kendex's id for the same tool.
    harness: &'static str,
    reads: Reads,
}

/// Which of these CI installs is decided in `.github/workflows/own-catalog.yml`;
/// the rest are reported uncovered when absent.
const PROBES: &[Probe] = &[
    Probe {
        bin: "codex",
        harness: "codex",
        reads: Reads::Cli(Reader {
            args: &["doctor", "--json"],
            loads: &[".codex/agents/reviewer.toml"],
            verdict: codex_loaded_every_agent,
            rejects: &[Reject {
                file: ".codex/agents/reviewer.toml",
                spoil: append_tags_table,
                marker: "tags = [\"review\"]",
            }],
        }),
    },
    Probe {
        bin: "opencode",
        harness: "opencode",
        reads: Reads::Cli(Reader {
            args: &["agent", "list"],
            loads: &[".config/opencode/agents/reviewer.md"],
            verdict: opencode_listed_the_agent,
            rejects: &[
                // opencode accepts an unknown key and rejects an unknown
                // value, so one control breaks the value...
                Reject {
                    file: ".config/opencode/agents/reviewer.md",
                    spoil: |body| body.replace("mode: subagent", "mode: not-a-mode"),
                    marker: "mode: not-a-mode",
                },
                // ...and the other breaks the frontmatter, which opencode
                // answers by listing the agent under its default mode
                // rather than by failing.
                Reject {
                    file: ".config/opencode/agents/reviewer.md",
                    spoil: open_a_yaml_sequence,
                    marker: "tags: [unclosed",
                },
            ],
        }),
    },
    Probe {
        bin: "gemini",
        harness: "gemini",
        reads: Reads::Cli(Reader {
            args: &["skills", "list"],
            // One command, two trees: listing skills also builds the user
            // agent registry, which reports every role file it could not
            // parse.
            loads: &[
                ".gemini/skills/release-notes/SKILL.md",
                ".gemini/agents/reviewer.md",
            ],
            verdict: gemini_read_both_trees,
            rejects: &[
                Reject {
                    file: ".gemini/agents/reviewer.md",
                    spoil: open_a_yaml_sequence,
                    marker: "tags: [unclosed",
                },
                // gemini reads a broken skill frontmatter leniently and
                // drops a skill that has none, so the skill half of the
                // verdict is controlled by taking the frontmatter away.
                Reject {
                    file: ".gemini/skills/release-notes/SKILL.md",
                    spoil: |_| "# release-notes\n\nno frontmatter, so no skill\n".to_string(),
                    marker: "no frontmatter, so no skill",
                },
            ],
        }),
    },
    Probe {
        bin: "copilot",
        harness: "copilot",
        reads: Reads::Cli(Reader {
            args: &["skill", "list"],
            loads: &[".copilot/skills/release-notes/SKILL.md"],
            verdict: copilot_listed_the_skill,
            rejects: &[Reject {
                file: ".copilot/skills/release-notes/SKILL.md",
                spoil: open_a_yaml_sequence,
                marker: "tags: [unclosed",
            }],
        }),
    },
    Probe {
        bin: "claude",
        harness: "claude",
        reads: Reads::NothingOffline(
            "`claude doctor` reads install state and settings, never the agent or \
             skill tree; `claude plugin list` sees nothing kendex writes; `-p` needs \
             a live session",
        ),
    },
    Probe {
        bin: "pi",
        harness: "pi",
        reads: Reads::NothingOffline(
            "`pi list` reads installed extension packages, not the rendered agents \
             or skills; `pi config` is a TUI and every other read wants a provider key",
        ),
    },
    Probe {
        bin: "cursor-agent",
        harness: "cursor",
        reads: Reads::NothingOffline(
            "cursor-agent ships no list or doctor command — every read starts an \
             authenticated session; kendex also renders for Cursor at project scope \
             only, which this global staging does not reach",
        ),
    },
];

/// A `tags` table, which Codex refuses in an agent file.
fn append_tags_table(body: &str) -> String {
    format!("{body}\ntags = [\"review\"]\n")
}

/// A flow sequence with no closing bracket: the frontmatter parses as YAML
/// nowhere.
fn open_a_yaml_sequence(body: &str) -> String {
    body.replacen("description:", "tags: [unclosed\ndescription:", 1)
}

fn codex_loaded_every_agent(said: &Said) -> Result<(), String> {
    // `codex doctor` exits non-zero in a staged home for the unrelated
    // reason that there are no credentials there, so the exit status is
    // not the signal — the report on stdout is.
    let report: serde_json::Value = serde_json::from_str(&said.out).map_err(|err| {
        format!(
            "codex doctor --json printed no report ({err}): {}",
            said.err
        )
    })?;
    let details = report
        .pointer("/checks/config.load/details")
        .ok_or_else(|| format!("codex doctor --json has no config.load check: {}", said.out))?;
    // Both keys are absent from a clean load, so a missing count is zero
    // warnings rather than a read that failed.
    let count = details
        .get("startup warnings")
        .and_then(serde_json::Value::as_str)
        .unwrap_or("0");
    if count == "0" {
        return Ok(());
    }
    let warnings = details
        .get("startup warning")
        .map_or_else(String::new, ToString::to_string);
    Err(format!(
        "codex raised {count} startup warning(s): {warnings}"
    ))
}

fn opencode_listed_the_agent(said: &Said) -> Result<(), String> {
    if !said.ok {
        return Err(format!("opencode agent list failed: {}", said.all()));
    }
    // The mode is half the assertion: frontmatter opencode cannot parse
    // falls back to the default mode instead of erroring, so matching the
    // name alone would pass a render it had already degraded.
    if said.all().contains("reviewer (subagent)") {
        return Ok(());
    }
    Err(format!(
        "opencode did not list `reviewer (subagent)`: {}",
        said.all()
    ))
}

fn gemini_read_both_trees(said: &Said) -> Result<(), String> {
    let all = said.all();
    if let Some(line) = all
        .lines()
        .find(|line| line.contains("Failed to load agent from"))
    {
        return Err(format!("gemini rejected a rendered agent: {}", line.trim()));
    }
    if !said.ok {
        return Err(format!("gemini skills list failed: {all}"));
    }
    // gemini prints the path it loaded each skill from, so the assertion
    // is on the rendered file rather than on the wording around it.
    if all.contains(".gemini/skills/release-notes/SKILL.md") {
        return Ok(());
    }
    Err(format!("gemini did not list the rendered skill: {all}"))
}

fn copilot_listed_the_skill(said: &Said) -> Result<(), String> {
    let all = said.all();
    // copilot names the file it could not read; matching the path keeps
    // the check off its own builtin skills.
    if let Some(line) = all
        .lines()
        .find(|line| line.contains("skills/release-notes/SKILL.md"))
    {
        return Err(format!(
            "copilot rejected the rendered skill: {}",
            line.trim()
        ));
    }
    if !said.ok {
        return Err(format!("copilot skill list failed: {all}"));
    }
    if all.contains("release-notes - Use this when writing release notes") {
        return Ok(());
    }
    Err(format!("copilot did not list the rendered skill: {all}"))
}

fn note(line: &str) {
    let _ = writeln!(std::io::stderr(), "smoke: {line}");
}

#[allow(clippy::expect_used)]
fn run(bin: &str, home: &Path, cwd: &Path, args: &[&str]) -> Output {
    Command::new(bin)
        .args(args)
        .current_dir(cwd)
        .env_clear()
        .envs(test_util::fixture_env(home))
        .env("PATH", std::env::var("PATH").unwrap_or_default())
        .env("NO_COLOR", "1")
        .output()
        .expect("the command runs")
}

fn ask(bin: &str, home: &Path, args: &[&str]) -> Said {
    let out = run(bin, home, home, args);
    Said {
        out: String::from_utf8_lossy(&out.stdout).into_owned(),
        err: String::from_utf8_lossy(&out.stderr).into_owned(),
        ok: out.status.success(),
    }
}

fn installed(bin: &str) -> bool {
    Command::new("sh")
        .args(["-c", &format!("command -v {bin}")])
        .output()
        .is_ok_and(|out| out.status.success())
}

fn enabled() -> bool {
    std::env::var("KENDEX_CLI_SMOKE").as_deref() == Ok("1")
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
    // Without a control file the source is read through the skills search
    // table, which yields agents and skills and silently leaves the hook,
    // the command and the MCP server on the floor — three kinds staged to
    // disk and installed nowhere.
    write(
        "kendex.toml",
        "[marketplace]\nname = \"smoke\"\ndescription = \"The round-trip fixtures.\"\n",
    );
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

/// Every rendered file the reader claims to load is really there, so a
/// probe can never pass over a tree kendex stopped writing.
fn staged(home: &Path, reader: &Reader, harness: &str) -> Result<(), String> {
    for relative in reader.loads {
        if !home.join(relative).is_file() {
            return Err(format!(
                "{harness}: kendex rendered no {relative}, so `{}` would read nothing",
                reader.args.join(" ")
            ));
        }
    }
    Ok(())
}

#[test]
#[allow(clippy::unwrap_used)]
fn every_harness_cli_reads_what_kendex_wrote() {
    if !enabled() {
        note("not run — set KENDEX_CLI_SMOKE=1 with the harness CLIs installed");
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    stage(home);

    let mut validated = 0_usize;
    let mut uncovered = Vec::new();
    let mut failed = Vec::new();
    for probe in PROBES {
        let reader = match &probe.reads {
            Reads::Cli(reader) => reader,
            Reads::NothingOffline(why) => {
                uncovered.push(probe.harness);
                note(&format!("{}: UNCOVERED — {why}", probe.harness));
                continue;
            }
        };
        if !installed(probe.bin) {
            uncovered.push(probe.harness);
            note(&format!(
                "{}: UNCOVERED — {} is not installed, so `{}` never ran",
                probe.harness,
                probe.bin,
                reader.args.join(" ")
            ));
            continue;
        }
        if let Err(missing) = staged(home, reader, probe.harness) {
            failed.push(missing);
            continue;
        }
        match (reader.verdict)(&ask(probe.bin, home, reader.args)) {
            Ok(()) => {
                validated += 1;
                note(&format!(
                    "{}: validated by `{} {}`",
                    probe.harness,
                    probe.bin,
                    reader.args.join(" ")
                ));
            }
            Err(why) => failed.push(format!("{} ({}): {why}", probe.harness, probe.bin)),
        }
    }

    note(&format!(
        "coverage: {validated} validated, {} uncovered ({}), {} failed",
        uncovered.len(),
        uncovered.join(", "),
        failed.len()
    ));
    assert!(failed.is_empty(), "{}", failed.join("\n"));
    // The whole point of the gate: a run that reached nothing proves
    // nothing, and must never be reported as a pass.
    assert!(
        validated > 0,
        "no harness CLI read anything, so nothing was checked — install at least one of: {}",
        PROBES
            .iter()
            .filter(|probe| matches!(probe.reads, Reads::Cli(_)))
            .map(|probe| probe.bin)
            .collect::<Vec<_>>()
            .join(", ")
    );
}

/// The control the probes exist for: put back a render the harness refuses
/// and watch its own probe go red. A probe that cannot fail is not a check.
#[test]
#[allow(clippy::unwrap_used)]
fn a_render_the_harness_refuses_reds_its_probe() {
    if !enabled() {
        note("not run — set KENDEX_CLI_SMOKE=1 with the harness CLIs installed");
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    stage(home);

    let mut controlled = 0_usize;
    for probe in PROBES {
        let Reads::Cli(reader) = &probe.reads else {
            continue;
        };
        if !installed(probe.bin) {
            note(&format!(
                "{}: control not run, {} is not installed",
                probe.harness, probe.bin
            ));
            continue;
        }
        for reject in reader.rejects {
            let path = home.join(reject.file);
            let good = std::fs::read_to_string(&path).unwrap();
            std::fs::write(&path, (reject.spoil)(&good)).unwrap();
            let spoiled = std::fs::read_to_string(&path).unwrap();
            // Before asking whether the CLI rejected the file, prove the
            // file really holds what the harness rejects: a spoiler that
            // stopped applying would otherwise leave this test passing on
            // a clean render the probe correctly accepted.
            assert!(
                spoiled.contains(reject.marker),
                "{}: the control wrote no `{}` into {}",
                probe.harness,
                reject.marker,
                reject.file
            );
            let verdict = (reader.verdict)(&ask(probe.bin, home, reader.args));
            std::fs::write(&path, &good).unwrap();
            assert!(
                verdict.is_err(),
                "{} ({}) accepted {} carrying `{}` — its probe cannot fail",
                probe.harness,
                probe.bin,
                reject.file,
                reject.marker
            );
            controlled += 1;
            note(&format!(
                "{}: control red on `{}` in {}",
                probe.harness, reject.marker, reject.file
            ));
        }
    }
    assert!(
        controlled > 0,
        "no probe was put under control, so none is known to be able to fail"
    );
}
