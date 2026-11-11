//! A skill's frontmatter names the hooks its install brings. The catalog's
//! own docs-writing skill and docs-writing-note hook are the fixture, so
//! the rows read the declaration consumers install.

use super::hooks::{findings_on, messages};
use super::*;

const HOOK: &str = "docs-writing-note";
const ALL: &str = "\"claude\", \"codex\", \"opencode\", \"cursor\", \"pi\", \"gemini\", \"copilot\", \"antigravity\"";
/// The edge the docs-writing skill declares; a row without it is the
/// control that the hook arrives by this line and nothing else.
const EDGE: &str = "  hooks: [docs-writing-note]\n";

/// Every project file that arms the hook, its script or its settings entry,
/// on the tools its own `harnesses` line names.
const ARMED: [&str; 6] = [
    ".claude/hooks/docs-writing-note.sh",
    ".claude/settings.json",
    ".codex/hooks.json",
    ".codex/hooks/docs-writing-note.sh",
    ".pi/kendex/hooks.json",
    ".pi/kendex/hooks/docs-writing-note.sh",
];
const ON: [HarnessId; 3] = [HarnessId::Claude, HarnessId::Codex, HarnessId::Pi];

/// Selecting docs-writing alone, with no set and no hook line, delivers the
/// hook and its settings entry on claude, codex and pi and nowhere else. A
/// hook the consumer kept removed or switched off stays unarmed, with the
/// skill's missing-dependency finding the skill-to-skill edge gives. The
/// lock rows are read only where the manifest declares no hook, since a
/// declared hook's records are its declaration's.
#[test]
#[allow(clippy::unwrap_used)]
fn a_skill_brings_the_hooks_its_frontmatter_names_where_each_hook_runs() {
    let removed =
        format!("missing required dependency: docs-writing requires {HOOK}, which is kept removed");
    let off =
        format!("missing required dependency: docs-writing requires {HOOK}, which is switched off");
    for (edge, extra, armed, recorded, finding) in [
        (true, "", ARMED.as_slice(), Some(ON.as_slice()), None),
        (false, "", [].as_slice(), Some([].as_slice()), None),
        (
            true,
            "[suppressed]\nhook = [\"docs-writing-note\"]\n",
            [].as_slice(),
            Some([].as_slice()),
            Some(removed.as_str()),
        ),
        (
            true,
            "[hooks.docs-writing-note]\nsource = \"cat\"\nenabled = false\n",
            [].as_slice(),
            None,
            Some(off.as_str()),
        ),
    ] {
        let f = world(edge, extra);
        let report = audit(&f.env, &f.scope).unwrap();
        let found: Vec<&str> = findings_on(&report, "docs-writing")
            .iter()
            .filter(|w| w.message.starts_with("missing required dependency:"))
            .map(|w| w.message.as_str())
            .collect();
        assert_eq!(
            found,
            finding.into_iter().collect::<Vec<_>>(),
            "{:?}",
            messages(&report)
        );
        apply::execute(&f.env, &report.plan).unwrap();
        assert!(installed(&f, "docs-writing") && installed(&f, "decider"));
        let arming: BTreeSet<String> = naming_the_hook(&f)
            .into_iter()
            .filter(|path| !path.ends_with(".disabled"))
            .collect();
        assert_eq!(
            arming,
            armed.iter().map(|path| (*path).to_owned()).collect(),
            "edge={edge} {extra}"
        );
        let Some(recorded) = recorded else {
            continue;
        };
        let lock = lock_of(&f);
        let tools: Vec<HarnessId> = HarnessId::ALL
            .into_iter()
            .filter(|tool| {
                lock.entries
                    .contains_key(&format!("hook:{HOOK}:{}", tool.name()))
            })
            .collect();
        assert_eq!(tools, recorded, "edge={edge} {extra}");
        // The hook stays derived: each record names the skill, and the
        // consumer manifest gains no hook declaration.
        assert!(!manifest_of(&f).declared(ItemKind::Hook).contains_key(HOOK));
        for tool in recorded {
            let entry = &lock.entries[&format!("hook:{HOOK}:{}", tool.name())];
            let by = kendex_core::lock::InstallRef {
                source: "cat".to_owned(),
                kind: ItemKind::Skill,
                name: "docs-writing".to_owned(),
                harness: *tool,
            };
            assert_eq!(
                entry.reasons,
                BTreeSet::from([Reason::RequiredBy { by }]),
                "{tool:?}"
            );
        }
    }
}

/// Every project path, relative, whose name or bytes name the hook,
/// leaving out kendex's own files: the manifest, the lock and its cache.
#[allow(clippy::unwrap_used)]
fn naming_the_hook(f: &Fixture) -> BTreeSet<String> {
    let project = &f.project;
    let records = [
        manifest::manifest_path(&f.env, &f.scope),
        lock_path(&f.env, &f.scope),
        project.join(".cache/kendex"),
    ];
    let mut found = BTreeSet::new();
    let mut pending = vec![project.to_path_buf()];
    while let Some(dir) = pending.pop() {
        for entry in fs::read_dir(&dir).unwrap() {
            let path = entry.unwrap().path();
            let kind = fs::symlink_metadata(&path).unwrap().file_type();
            if records.iter().any(|record| path.starts_with(record)) {
                continue;
            }
            if kind.is_dir() {
                pending.push(path);
                continue;
            }
            if !kind.is_file() {
                continue;
            }
            let relative = path.strip_prefix(project).unwrap().to_string_lossy();
            let named = relative.contains(HOOK)
                || String::from_utf8_lossy(&fs::read(&path).unwrap()).contains(HOOK);
            if named {
                found.insert(relative.into_owned());
            }
        }
    }
    found
}

/// The catalog's own docs-writing skill and docs-writing-note hook, the
/// skill's `hooks` line dropped where `edge` is false, installed into a
/// project that declares only the skill for every tool.
#[allow(clippy::unwrap_used)]
pub(super) fn world(edge: bool, extra: &str) -> Fixture {
    let f = fixture("");
    let checkout = test_util::checkout_root();
    let skill_md = fs::read_to_string(checkout.join("skills/docs-writing/SKILL.md")).unwrap();
    assert_eq!(
        skill_md.matches(EDGE).count(),
        1,
        "docs-writing declares the hook edge once"
    );
    let skill_md = match edge {
        true => skill_md,
        false => skill_md.replace(EDGE, ""),
    };
    skill(&f.source, "decider", "");
    let dir = f.source.join("skills/docs-writing");
    fs::create_dir_all(&dir).unwrap();
    fs::write(dir.join("SKILL.md"), skill_md).unwrap();
    fs::create_dir_all(f.source.join("hooks")).unwrap();
    fs::write(
        f.source.join(format!("hooks/{HOOK}.sh")),
        fs::read(checkout.join(format!("hooks/{HOOK}.sh"))).unwrap(),
    )
    .unwrap();
    fs::write(f.source.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
    fs::write(
        f.project.join("kendex.toml"),
        format!(
            "schema = 7\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [{ALL}]\nmethod = \"copy\"\n\n[skills.docs-writing]\nsource = \"cat\"\n\n{extra}",
            source_path(&f.source)
        ),
    )
    .unwrap();
    f
}
