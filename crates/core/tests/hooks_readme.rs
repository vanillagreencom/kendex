//! `hooks/README.md` is rendered from this catalog's own hooks through core's
//! hook delivery decision, and the committed file is held to that rendering.
//! Every cell is `hook::delivery` for one hook on one harness at project
//! scope, the pi-hooks carrier registered the way a Pi install enforces
//! hooks. A harness the hook's own `harnesses:` line leaves out, and any
//! refusal other than the by-name-only one, shows the hook's
//! `Not run on <id>: <reason>.` sentence instead, and a missing or
//! unterminated sentence fails the rendering naming the hook and harness.
//!
//! Every failure opens with `hooks-readme: <key>=<value>`, English below it.
//! Regenerate the file with the command in `REGENERATE`.
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::{checkout_root, rooted};

use std::fs;
use std::path::PathBuf;

use kendex_core::env::{Env, FakeOs};
use kendex_core::harness::{Enforcement, hook_enforcement};
use kendex_core::hook::{Delivery, HookSource, HookSpec, by_name_only, delivery, parse_hook};
use kendex_core::model::{HarnessId, Scope};

const REGENERATE: &str =
    "cargo test -p kendex-core --test hooks_readme -- --ignored regenerate_hooks_readme";

/// The project every hook is judged in: a fake home whose project registers
/// the pi-hooks carrier in its own Pi settings.
struct World {
    _tmp: tempfile::TempDir,
    env: Env,
    scope: Scope,
}

#[allow(
    clippy::expect_used,
    reason = "a fixture that cannot be built is the test's own failure"
)]
fn world() -> World {
    let tmp = tempfile::tempdir().expect("a scratch directory");
    let home = rooted(&tmp);
    let project = home.join("app");
    fs::create_dir_all(project.join(".pi")).expect("the project's Pi directory");
    fs::write(
        project.join(".pi/settings.json"),
        r#"{ "packages": ["./packages/@vanillagreen/pi-hooks"] }"#,
    )
    .expect("the carrier registration");
    World {
        env: Env::fake(&home, FakeOs::Linux),
        scope: Scope::Project { root: project },
        _tmp: tmp,
    }
}

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

/// The reason in `Not run on <id>: <reason>.`: the text up to the first
/// period followed by a space, or up to the period that ends the description.
fn reason(description: &str, hook: &str, harness: HarnessId) -> Result<String, String> {
    let marker = format!("Not run on {}: ", harness.name());
    let Some(start) = description.find(&marker) else {
        return Err(format!(
            "hooks-readme: missing-reason={hook}:{id}\nthe hook does not run on {id} and its description carries no '{marker}<reason>.' sentence",
            id = harness.name()
        ));
    };
    let rest = &description[start + marker.len()..];
    match rest.find(". ") {
        Some(end) => Ok(rest[..end].to_owned()),
        None => rest.strip_suffix('.').map(str::to_owned).ok_or_else(|| {
            format!(
                "hooks-readme: unterminated-reason={hook}:{id}\nthe '{marker}' sentence ends in no period followed by a space or the end of the description",
                id = harness.name()
            )
        }),
    }
}

/// One cell: core's delivery answer, or the hook's own reason where the hook
/// does not run there.
fn cell(world: &World, spec: &HookSpec, harness: HarnessId) -> Result<String, String> {
    if spec.applies_to(harness) {
        match delivery(&world.env, &world.scope, harness, spec) {
            Delivery::Registered | Delivery::InAgentFile => return Ok("enforced".to_owned()),
            Delivery::Advisory => return Ok("advisory".to_owned()),
            Delivery::NotInstallable(refusal) if refusal == by_name_only(harness) => {
                return Ok("not named".to_owned());
            }
            Delivery::NotInstallable(_) => {}
        }
    }
    Ok(reason(&spec.description, &spec.name, harness)?.replace('|', "\\|"))
}

/// Names joined the way a sentence lists them: `A`, `A and B`, `A, B and C`.
fn listed(names: &[&str]) -> String {
    match names.split_last() {
        None => String::new(),
        Some((last, [])) => (*last).to_owned(),
        Some((last, rest)) => format!("{} and {last}", rest.join(", ")),
    }
}

/// The whole README, or every finding the hooks' frontmatter holds.
fn render(world: &World, hooks: &[HookSource]) -> Result<String, Vec<String>> {
    // Columns: the harnesses that run hooks, then the ones that take them as
    // prose, each in `HarnessId::ALL` order.
    let advisory = |harness: &HarnessId| {
        hook_enforcement(&world.env, &world.scope, *harness) == Enforcement::Advisory
    };
    let columns: Vec<HarnessId> = HarnessId::ALL
        .into_iter()
        .filter(|harness| !advisory(harness))
        .chain(HarnessId::ALL.into_iter().filter(advisory))
        .collect();

    let mut findings = Vec::new();
    let mut list = String::new();
    let mut rows = String::new();
    for hook in hooks {
        list.push_str(&format!(
            "- `{}`: {}\n",
            hook.name,
            hook.human_summary().unwrap_or_default()
        ));
        let spec = HookSpec::from(hook.clone());
        let mut row = format!("| `{}` |", spec.name);
        for harness in &columns {
            match cell(world, &spec, *harness) {
                Ok(text) => row.push_str(&format!(" {text} |")),
                Err(finding) => findings.push(finding),
            }
        }
        rows.push_str(&row);
        rows.push('\n');
    }
    if !findings.is_empty() {
        return Err(findings);
    }

    let advisory_names: Vec<&str> = columns
        .iter()
        .filter(|harness| advisory(harness))
        .map(|harness| harness.display_name())
        .collect();
    let by_name: String = columns
        .iter()
        .filter(|harness| harness.hooks_by_name_only())
        .map(|harness| format!("{}.", by_name_only(*harness)))
        .collect::<Vec<_>>()
        .join(" ");
    let header: String = columns
        .iter()
        .map(|harness| format!(" {} |", harness.name()))
        .collect();
    let rule: String = columns.iter().map(|_| " --- |").collect();
    Ok(format!(
        "# hooks\n\nThe catalog's hooks, one script each. `crates/core/tests/hooks_readme.rs` renders this file from each hook's frontmatter through kendex's hook delivery decision, and fails when the committed file differs.\n\n## Hooks\n\n{list}\n## Harnesses\n\n- `enforced`: the harness runs the hook on its event.\n- `advisory`: {} run no hooks, so the hook's description reaches the agent as an instruction.\n- `not named`: {by_name}\n- Any other cell is the hook's own reason that harness does not run it.\n\n| Hook |{header}\n| --- |{rule}\n{rows}",
        listed(&advisory_names)
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
        "hooks-readme: drift=hooks/README.md\nline {line} is not what core's hook delivery renders; regenerate the file with: {REGENERATE}"
    ))
}

fn rendered(world: &World, hooks: &[HookSource]) -> String {
    render(world, hooks).unwrap_or_else(|findings| panic!("{}", findings.join("\n")))
}

#[test]
fn the_committed_readme_is_what_hook_delivery_renders() {
    let world = world();
    let committed = fs::read_to_string(readme_path()).unwrap_or_default();
    if let Err(finding) = compare(&committed, &rendered(&world, &catalog_hooks())) {
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
    let world = world();
    fs::write(readme_path(), rendered(&world, &catalog_hooks()))
        .expect("hooks/README.md is writable");
}

/// Each rule refuses the one defect its row plants into this catalog's own
/// hooks, and names it on its keyed line.
#[test]
#[allow(
    clippy::expect_used,
    reason = "a planted defect that is not refused is the failure this test names"
)]
fn each_planted_defect_is_refused_on_its_keyed_line() {
    let world = world();
    let hooks = catalog_hooks();
    let clean = rendered(&world, &hooks);

    let edited = clean.replacen("| enforced |", "| advisory |", 1);
    assert_ne!(edited, clean, "the planted cell edit changed nothing");
    let drift = compare(&edited, &clean).expect_err("a hand-edited cell is refused");
    assert_eq!(
        drift.lines().next(),
        Some("hooks-readme: drift=hooks/README.md")
    );

    let copilot_reason = "Not run on copilot: its subagentStop names the agent type `task`, the tool rather than the agent, and carries no `stop_hook_active`. ";
    let antigravity_period = "carries no `stop_hook_active`.";
    for (hook, planted, key) in [
        (
            "reviewer-stop-check",
            (copilot_reason, ""),
            "hooks-readme: missing-reason=reviewer-stop-check:copilot",
        ),
        (
            "lane-mail-check",
            (antigravity_period, "carries no `stop_hook_active`"),
            "hooks-readme: unterminated-reason=lane-mail-check:antigravity",
        ),
    ] {
        let mut planted_hooks = hooks.clone();
        let target = planted_hooks
            .iter_mut()
            .find(|source| source.name == hook)
            .unwrap_or_else(|| panic!("the catalog holds {hook}"));
        let before = target.description.clone();
        target.description = before.replacen(planted.0, planted.1, 1);
        assert_ne!(
            target.description, before,
            "the planted edit to {hook} changed nothing"
        );
        let findings = render(&world, &planted_hooks).expect_err("the planted hook is refused");
        let firsts: Vec<&str> = findings
            .iter()
            .filter_map(|finding| finding.lines().next())
            .collect();
        assert_eq!(firsts, vec![key]);
    }
}
