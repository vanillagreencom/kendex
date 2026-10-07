//! `hooks/README.md` is rendered from this catalog's own hooks, and the
//! committed file is held to that rendering. The rendering also holds each
//! hook's tool sentences to the reach the package's supported-tools row
//! reads: `hook::hook_reach` for one hook on one harness, fed the
//! capability table's enforcement, as `package::support` feeds it. A
//! harness the hook does not run on, other than one core states the reason
//! for itself, needs the hook's `Not run on <id>: <reason>.` sentence, read
//! by `hook::stated_reason`, the reader the row takes. A missing or
//! unterminated sentence fails the rendering naming the hook and harness.
//! Where core states the reason, the hook's own sentence is optional and
//! replaces core's, and an unterminated one fails: the row would drop it
//! and show core's. On a harness the hook runs on, an `On <id>:` fallback
//! sentence is optional, and an unterminated one fails: the row would list
//! the harness as plainly supported and drop the fallback. A sentence in
//! the wrong form fails too: `Not run on <id>:` for a harness the hook runs
//! on, `On <id>:` for one it does not, and either for one that takes it as
//! advisory prose, where the row reads neither. A hook that reaches a
//! harness where a companion it requires is withheld fails too: the row
//! would say it runs there, and the engine installs it nowhere, so its
//! `harnesses:` line must leave that harness out.
//!
//! Every failure opens with `hooks-readme: <key>=<value>`, English below it.
//! Regenerate the file with the command in `REGENERATE`.
#![cfg(unix)]

use crate::test_util;
use test_util::checkout_root;

use std::fs;
use std::path::PathBuf;

use kendex_core::harness::capabilities;
use kendex_core::hook::{
    HookSource, HookSpec, Reach, Refusal, Stated, ToolSentence, hook_reach, parse_hook,
    stated_reason,
};
use kendex_core::model::{HarnessId, ItemKind};

const REGENERATE: &str =
    "cargo test -p kendex-core --test integration -- --ignored regenerate_hooks_readme";

fn readme_path() -> PathBuf {
    checkout_root().join("hooks/README.md")
}

/// Every catalog hook, parsed by the catalog's own reader, in file-name order.
#[allow(
    clippy::expect_used,
    reason = "an unreadable hooks directory leaves nothing to judge"
)]
fn catalog_hooks() -> Vec<HookSource> {
    let dir = checkout_root().join("hooks");
    let mut paths: Vec<PathBuf> = fs::read_dir(&dir)
        .expect("hooks/ reads")
        .map(|entry| entry.expect("a hooks/ entry reads").path())
        .filter(|path| path.extension().is_some_and(|ext| ext == "sh"))
        .collect();
    paths.sort();
    assert!(
        !paths.is_empty(),
        "hooks-readme: hooks=none\n{} holds no hook script",
        dir.display()
    );
    paths
        .iter()
        .map(|path| {
            let text = fs::read_to_string(path).expect("a hook script reads");
            parse_hook(&text).unwrap_or_else(|problem| {
                panic!("hooks-readme: unreadable={}\n{problem}", path.display())
            })
        })
        .collect()
}

/// The finding for a `form` sentence naming `harness` that the reader
/// cannot end, so the supported-tools row drops it.
fn unterminated(spec: &HookSpec, form: ToolSentence, harness: HarnessId) -> String {
    let (hook, id) = (&spec.name, harness.name());
    let (key, marker, dropped) = match form {
        ToolSentence::NotRun => (
            "unterminated-reason",
            format!("Not run on {id}: "),
            "the row shows core's reason or none in its place",
        ),
        ToolSentence::On => (
            "unterminated-fallback",
            format!("On {id}: "),
            "the row lists the harness as plainly supported and shows no fallback",
        ),
    };
    format!(
        "hooks-readme: {key}={hook}:{id}\nthe '{marker}' sentence ends in no period followed by a space or the end of the description, so {dropped}"
    )
}

/// The hook's own `Not run on <id>: <reason>.` sentence is there, or the
/// finding naming why it is not.
fn reason(spec: &HookSpec, harness: HarnessId) -> Result<(), String> {
    let (hook, id) = (&spec.name, harness.name());
    match stated_reason(&spec.description, ToolSentence::NotRun, harness) {
        Stated::Reason(_) => Ok(()),
        Stated::Absent => Err(format!(
            "hooks-readme: missing-reason={hook}:{id}\nthe hook does not run on {id} and its description carries no 'Not run on {id}: <reason>.' sentence"
        )),
        Stated::Unterminated => Err(unterminated(spec, ToolSentence::NotRun, harness)),
    }
}

/// The hook's optional `form` sentence naming `harness` ends, or the
/// finding naming it.
fn terminated(spec: &HookSpec, form: ToolSentence, harness: HarnessId) -> Result<(), String> {
    match stated_reason(&spec.description, form, harness) {
        Stated::Reason(_) | Stated::Absent => Ok(()),
        Stated::Unterminated => Err(unterminated(spec, form, harness)),
    }
}

/// No `form` sentence names `harness`, where the hook's `standing` there
/// makes that sentence false, or the finding naming it.
fn absent(
    spec: &HookSpec,
    standing: &Standing,
    form: ToolSentence,
    harness: HarnessId,
) -> Result<(), String> {
    let (hook, id) = (&spec.name, harness.name());
    if stated_reason(&spec.description, form, harness) == Stated::Absent {
        return Ok(());
    }
    let why = match standing {
        Standing::Runs => format!(
            "the hook runs on {id}, so its 'Not run on {id}: ' sentence is false; a fallback there is 'On {id}: <reason>.'"
        ),
        Standing::Advisory => format!(
            "{id} takes the hook as advisory prose, which the supported-tools row shows without reading any sentence naming {id}; drop the sentence"
        ),
        Standing::NotRun { .. } => format!(
            "the hook does not run on {id}, so its 'On {id}: ' sentence names no fallback; the reason there is 'Not run on {id}: <reason>.'"
        ),
    };
    Err(format!("hooks-readme: wrong-form={hook}:{id}\n{why}"))
}

/// The hook's reach on `harness`, as the supported-tools row judges it.
fn reach(spec: &HookSpec, harness: HarnessId) -> Reach {
    hook_reach(
        harness,
        capabilities(harness, ItemKind::Hook).enforcement,
        spec,
    )
}

/// Whether a directly required companion never runs on `harness`. The
/// dependency walk (`engine/deps.rs::companion`) skips companions whose
/// own `harnesses:` line excludes it: they are not required there.
fn companion_absent(hook: &HookSource, catalog: &[HookSpec], harness: HarnessId) -> bool {
    hook.requires.iter().any(|name| {
        catalog.iter().any(|spec| {
            spec.name == *name
                && spec.applies_to(harness)
                && matches!(reach(spec, harness), Reach::Refused(_))
        })
    })
}

/// How the hook reaches one harness, which decides the sentence the hook
/// may state there.
enum Standing {
    /// The harness runs the hook: a fallback is an `On <id>:` sentence,
    /// which must end, and a `Not run on <id>:` sentence is false.
    Runs,
    /// Installed, run by no hook runner: core states it, the
    /// supported-tools row reads neither sentence, and either is false.
    Advisory,
    /// Not run: `stated` is whether core states the reason itself, as it
    /// does for the by-name-only refusal and a harness that takes no hooks,
    /// where the hook's own `Not run on <id>:` sentence is optional and
    /// must end; an `On <id>:` sentence is false.
    NotRun { stated: bool },
}

fn standing(spec: &HookSpec, harness: HarnessId) -> Standing {
    match reach(spec, harness) {
        Reach::Registry | Reach::InAgentFile => Standing::Runs,
        Reach::Advisory => Standing::Advisory,
        Reach::Refused(refusal) => Standing::NotRun {
            stated: match refusal {
                Refusal::ByNameOnly | Refusal::NoHooks => true,
                Refusal::LeftOut | Refusal::NeverFires => false,
            },
        },
    }
}

/// Every finding the hook's sentences hold on `harness`: one in the wrong
/// form, a reason the hook owes and does not state, a sentence the reader
/// cannot end, and a reach its
/// withheld companion (`withheld`, [`companion_absent`]'s answer) denies.
fn judged(spec: &HookSpec, withheld: bool, harness: HarnessId) -> Vec<String> {
    let (hook, id) = (&spec.name, harness.name());
    let standing = standing(spec, harness);
    let mut checks = match standing {
        Standing::Runs => vec![
            absent(spec, &standing, ToolSentence::NotRun, harness),
            terminated(spec, ToolSentence::On, harness),
        ],
        Standing::Advisory => vec![
            absent(spec, &standing, ToolSentence::On, harness),
            absent(spec, &standing, ToolSentence::NotRun, harness),
        ],
        Standing::NotRun { stated: true } => vec![
            absent(spec, &standing, ToolSentence::On, harness),
            terminated(spec, ToolSentence::NotRun, harness),
        ],
        Standing::NotRun { stated: false } => vec![
            absent(spec, &standing, ToolSentence::On, harness),
            reason(spec, harness),
        ],
    };
    if withheld && !matches!(standing, Standing::NotRun { .. }) {
        checks.push(Err(format!(
            "hooks-readme: companion-withheld={hook}:{id}\na companion the hook requires never runs on {id}, so the hook is installed nowhere there; leave {id} off its harnesses line and state 'Not run on {id}: <reason>.'"
        )));
    }
    checks.into_iter().filter_map(Result::err).collect()
}

/// The whole README, or every finding the hooks' frontmatter holds.
fn render(hooks: &[HookSource]) -> Result<String, Vec<String>> {
    let catalog: Vec<HookSpec> = hooks.iter().cloned().map(HookSpec::from).collect();
    let mut findings = Vec::new();
    let mut list = String::new();
    for hook in hooks {
        list.push_str(&format!(
            "- `{}`: {}\n",
            hook.name,
            hook.human_summary().unwrap_or_default()
        ));
        let spec = HookSpec::from(hook.clone());
        for harness in HarnessId::ALL {
            let withheld = companion_absent(hook, &catalog, harness);
            findings.extend(judged(&spec, withheld, harness));
        }
    }
    if !findings.is_empty() {
        return Err(findings);
    }
    Ok(format!(
        "# hooks\n\nThe catalog's hooks, one script each. `crates/core/tests/hooks_readme.rs` renders this file from each hook's frontmatter, and fails when the committed file differs. The tools a hook does not run on, each with its reason, are on its package page and in `kendex show hook <name>` and `kendex index --json`.\n\n{list}"
    ))
}

/// The committed README against the rendering.
fn compare(committed: &str, rendered: &str) -> Result<(), String> {
    if committed == rendered {
        return Ok(());
    }
    let line = committed
        .lines()
        .zip(rendered.lines())
        .position(|(left, right)| left != right)
        .unwrap_or_else(|| committed.lines().count().min(rendered.lines().count()))
        + 1;
    Err(format!(
        "hooks-readme: drift=hooks/README.md\nline {line} is not what the hooks' frontmatter renders; regenerate the file with: {REGENERATE}"
    ))
}

fn rendered(hooks: &[HookSource]) -> String {
    render(hooks).unwrap_or_else(|findings| panic!("{}", findings.join("\n")))
}

#[test]
fn the_committed_readme_is_what_the_hooks_render() {
    let committed = fs::read_to_string(readme_path()).unwrap_or_default();
    if let Err(finding) = compare(&committed, &rendered(&catalog_hooks())) {
        panic!("{finding}");
    }
}

#[test]
#[ignore = "writes hooks/README.md"]
#[allow(
    clippy::expect_used,
    reason = "a README that cannot be written is the command's own failure"
)]
fn regenerate_hooks_readme() {
    fs::write(readme_path(), rendered(&catalog_hooks())).expect("hooks/README.md is writable");
}

#[test]
#[allow(
    clippy::expect_used,
    reason = "the catalog must hold the hook and its companion"
)]
fn a_companion_is_required_only_on_its_own_harnesses() {
    let hooks = catalog_hooks();
    let hook = hooks
        .iter()
        .find(|source| source.name == "lane-mail-check")
        .expect("the requiring hook");
    let catalog: Vec<HookSpec> = hooks.iter().cloned().map(HookSpec::from).collect();
    let mut undeliverable = catalog.clone();
    undeliverable
        .iter_mut()
        .find(|spec| spec.name == "lane-mail-deliver")
        .expect("the companion")
        .event = "TaskCompleted".to_owned();

    // A companion counts only where its own harnesses line applies:
    // critical-path-deny and stop-failure-row leave out Codex, and
    // lane-mail-deliver leaves out Gemini and Antigravity, so its
    // unsupported event withholds the requirer on Codex and Copilot alone.
    // Each true answer means withheld, not delivered.
    let rows = [
        (HarnessId::Claude, [false, false]),
        (HarnessId::Codex, [false, true]),
        (HarnessId::Pi, [false, false]),
        (HarnessId::Gemini, [false, false]),
        (HarnessId::Copilot, [false, true]),
        (HarnessId::Antigravity, [false, false]),
        (HarnessId::Opencode, [false, false]),
        (HarnessId::Cursor, [false, false]),
    ];
    for (harness, expected) in rows {
        assert_eq!(
            [
                companion_absent(hook, &catalog, harness),
                companion_absent(hook, &undeliverable, harness),
            ],
            expected,
            "companion applicability on {}",
            harness.name()
        );
    }
}

/// One planted defect: the hook it edits, the edit, and the keyed lines
/// that refuse it.
type PlantedRow = (&'static str, fn(&mut HookSource), &'static [&'static str]);

/// Every planted defect, each in one of this catalog's own hooks.
#[allow(
    clippy::too_many_lines,
    reason = "one table: planted defects judged by one render, each row a hook edit of its own"
)]
fn planted_rows() -> [PlantedRow; 10] {
    [
        // Codex and Copilot never fire TaskCompleted. The planted Copilot
        // companion reason leaves the Codex companion without one, and the
        // requirer still reaches both tools its companion is withheld on.
        (
            "lane-mail-deliver",
            |source| {
                source.event = "TaskCompleted".to_owned();
                source.description.push_str(" Not run on copilot: planted.");
            },
            &[
                "hooks-readme: companion-withheld=lane-mail-check:codex",
                "hooks-readme: companion-withheld=lane-mail-check:copilot",
                "hooks-readme: missing-reason=lane-mail-deliver:codex",
            ],
        ),
        (
            "reviewer-read-only",
            |source| {
                source.description = source.description.replacen(
                    "Not run on copilot: its preToolUse payload names no calling agent, only the caller's own session, and its subagentStart names the lead's session and no subagent id, so a reviewer's tool call cannot be joined to the reviewer (Copilot hooks reference, CLI 1.0.91). ",
                    "",
                    1,
                );
            },
            &["hooks-readme: missing-reason=reviewer-read-only:copilot"],
        ),
        (
            "lane-mail-check",
            |source| {
                source.description = source.description.replacen(
                    "carries no `stop_hook_active`.",
                    "carries no `stop_hook_active`",
                    1,
                );
            },
            &["hooks-readme: unterminated-reason=lane-mail-check:antigravity"],
        ),
        // Codex runs session-end-row with a fallback; Antigravity never
        // fires SessionEnd, so its sentence states no fallback.
        (
            "session-end-row",
            |source| {
                source.description =
                    source
                        .description
                        .replacen("On codex: ", "Not run on codex: ", 1);
            },
            &["hooks-readme: wrong-form=session-end-row:codex"],
        ),
        (
            "session-end-row",
            |source| {
                source.description =
                    source
                        .description
                        .replacen("Not run on antigravity: ", "On antigravity: ", 1);
            },
            &[
                "hooks-readme: wrong-form=session-end-row:antigravity",
                "hooks-readme: missing-reason=session-end-row:antigravity",
            ],
        ),
        // Antigravity fires PreToolUse and is reached only by a hook that
        // names it: core states that reason, so the hook owes none, and a
        // fallback sentence there is false.
        (
            "block-bare-cd",
            |source| {
                source
                    .description
                    .push_str(" On antigravity: a planted fallback.");
            },
            &["hooks-readme: wrong-form=block-bare-cd:antigravity"],
        ),
        // The hook's own reason there replaces core's, so it must end, or
        // the row drops it and shows core's.
        (
            "block-bare-cd",
            |source| {
                source
                    .description
                    .push_str(" Not run on antigravity: an unterminated reason");
            },
            &["hooks-readme: unterminated-reason=block-bare-cd:antigravity"],
        ),
        // Codex runs block-bare-cd: a fallback there must end, or the row
        // drops it.
        (
            "block-bare-cd",
            |source| {
                source
                    .description
                    .push_str(" On codex: an unterminated fallback");
            },
            &["hooks-readme: unterminated-fallback=block-bare-cd:codex"],
        ),
        // OpenCode and Cursor take block-bare-cd as advisory prose, where
        // the row reads neither sentence.
        (
            "block-bare-cd",
            |source| {
                source
                    .description
                    .push_str(" On opencode: a planted fallback.");
            },
            &["hooks-readme: wrong-form=block-bare-cd:opencode"],
        ),
        (
            "block-bare-cd",
            |source| {
                source.description.push_str(" Not run on cursor: planted.");
            },
            &["hooks-readme: wrong-form=block-bare-cd:cursor"],
        ),
    ]
}

/// Each rule refuses the one defect its row plants into this catalog's own
/// hooks, and names it on its keyed line.
#[test]
#[allow(
    clippy::expect_used,
    reason = "a planted defect that is not refused is the failure this test names"
)]
fn each_planted_defect_is_refused_on_its_keyed_line() {
    let hooks = catalog_hooks();
    let clean = rendered(&hooks);

    let edited = clean.replacen("- `block-argv-kill`: ", "- `block-argv-kill`: Edited. ", 1);
    assert_ne!(edited, clean, "the planted line edit changed nothing");
    let drift = compare(&edited, &clean).expect_err("a hand-edited line is refused");
    assert_eq!(
        drift.lines().next(),
        Some("hooks-readme: drift=hooks/README.md")
    );

    for (hook, plant, keys) in planted_rows() {
        let mut planted_hooks = hooks.clone();
        let target = planted_hooks
            .iter_mut()
            .find(|source| source.name == hook)
            .unwrap_or_else(|| panic!("the catalog holds {hook}"));
        let before = target.clone();
        plant(target);
        assert_ne!(
            *target, before,
            "the planted edit to {hook} changed nothing"
        );
        let findings = render(&planted_hooks).expect_err("the planted hook is refused");
        let firsts: Vec<&str> = findings
            .iter()
            .filter_map(|finding| finding.lines().next())
            .collect();
        assert_eq!(firsts, keys);
    }
}
