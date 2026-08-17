//! OpenCode hook presence. OpenCode loads what its config's `instructions`
//! array names, and it parses that config as JSONC — so the entry is half
//! the install, and a comment in the file is not a reason to doubt it.

use super::super::*;
use super::{install_hook_for, phantom_note, unverifiable_note};

fn opencode_hook_lock(source: &Path, name: &str) -> LockFile {
    let mut entry = locked(source, ItemKind::Hook, name);
    entry.harnesses = vec!["opencode".into()];
    let mut lock = LockFile::default();
    lock.add(entry);
    lock
}

/// OpenCode loads the instruction files its `opencode.json` names. The file
/// alone is prose no agent ever sees, so presence has to demand the entry too
/// — the same two-artifact question the Claude and Codex checks ask, on the
/// one harness that was still answering it from the file alone.
#[test]
fn an_opencode_hook_needs_its_instruction_entry_not_just_its_file() {
    with_sandbox("opencode-registration", |project, source| {
        write_hook(source, "guard");
        install_hook_for(source, "guard", crate::harness::Harness::OpenCode);
        let lock = opencode_hook_lock(source, "guard");

        // Control: the full install is clean.
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(report.phantom.is_empty(), "control: {report:?}");

        let config_path = project.join("opencode.json");
        let installed = std::fs::read_to_string(&config_path).unwrap();
        assert!(
            installed.contains("vstack-hook-guard.md"),
            "installer must reference the instruction file: {installed}"
        );

        // Control: a differently spelled path to the same file still counts.
        std::fs::write(
            &config_path,
            installed.replace(
                ".opencode/instructions/vstack-hook-guard.md",
                "./.opencode/./instructions/vstack-hook-guard.md",
            ),
        )
        .unwrap();
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(
            report.phantom.is_empty(),
            "an equivalent path is the same registration: {report:?}"
        );

        // The file survives, the reference does not — opencode will never
        // load this hook, so it is drift.
        std::fs::write(
            &config_path,
            installed.replace(
                ".opencode/instructions/vstack-hook-guard.md",
                ".opencode/instructions/somebody-elses.md",
            ),
        )
        .unwrap();
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert_eq!(names(&report.phantom), vec!["guard"], "{report:?}");
        assert!(
            phantom_note(&report).contains("instruction present but not referenced"),
            "{report:?}"
        );
        assert!(report.has_drift());

        // A config nothing can parse is not a missing registration: nothing
        // can say, and reinstalling repairs no unparseable file.
        std::fs::write(&config_path, "{\"instructions\": [\n").unwrap();
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert_eq!(names(&report.unverifiable), vec!["guard"], "{report:?}");
        assert!(
            unverifiable_note(&report).contains("registration unverifiable"),
            "{report:?}"
        );
    });
}

/// The config OpenCode resolves, in the spelling OpenCode resolves it by.
///
/// OpenCode reads `opencode.jsonc` and parses it — like `opencode.json` — as
/// JSONC, so comments and a trailing comma are a working install. Reading it
/// with a strict parser reported that install as unverifiable and told the
/// user to repair a file nothing was wrong with.
#[test]
fn an_opencode_jsonc_config_is_a_clean_install_not_an_unverifiable_one() {
    with_sandbox("opencode-jsonc", |project, source| {
        write_hook(source, "guard");
        install_hook_for(source, "guard", crate::harness::Harness::OpenCode);
        let lock = opencode_hook_lock(source, "guard");

        let json_path = project.join("opencode.json");
        let installed = std::fs::read_to_string(&json_path).unwrap();

        // Same registration, moved to the `.jsonc` spelling and written the
        // way a user writes it.
        let jsonc = installed.replace(
            '{',
            "{\n  // the hooks below are managed by vstack\n  \"theme\": \"opencode\",",
        );
        let jsonc = jsonc.replace("\n}", ",\n}");
        std::fs::write(project.join("opencode.jsonc"), &jsonc).unwrap();
        std::fs::remove_file(&json_path).unwrap();

        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(
            report.unverifiable.is_empty(),
            "a JSONC config OpenCode reads is not unverifiable: {report:?}"
        );
        assert!(
            report.phantom.is_empty(),
            "the registration is right there: {report:?}"
        );
        assert!(!report.has_drift(), "{report:?}");

        // ...and the file was not touched to get that answer.
        assert_eq!(
            std::fs::read_to_string(project.join("opencode.jsonc")).unwrap(),
            jsonc,
            "a read must not rewrite the config"
        );
    });
}
