//! Previous-format evidence stays sufficient for the same offline removal.

use super::*;
use kendex_core::error::{CoreError, ProvenanceStep};
use kendex_core::lock::{LOCK_VERSION, save};

// Literal expanded v11, not output synthesized by the compact writer.
// dev is withheld (no installed entry); another recorder can retain a
// competing reading. The catalog is unavailable for both removal runs.
const V11: &str = r#"{
  "version": 11,
  "entries": {
    "skill:github:claude": {
      "name":"github", "kind":"skill", "harness":"claude", "source":"cat",
      "sourceRepo":@repo@, "sourceHash":"abc", "enabled":true,
      "emitted":{"kind":"skill","name":"github","paths":[".claude/skills/github"]},
      "reasons":[{"reason":"requested"},{"reason":"required-by","by":{"source":"cat","kind":"skill","name":"dev","harness":"claude"}}]
      @ancestry@
    }
    @other@
  }
}"#;
const ROOTED: &str = r#"{"installation":{"source":"cat","kind":"skill","name":"dev","harness":"claude"},"sourceRepo":@repo@,"reasons":[{"reason":"requested"}]}"#;
const EMPTY: &str = r#"{"installation":{"source":"cat","kind":"skill","name":"dev","harness":"claude"},"sourceRepo":@repo@,"reasons":[]}"#;

#[derive(Debug, PartialEq, Eq)]
enum Answer {
    Suppressed,
    Removed,
    Missing,
    Held,
}

#[allow(clippy::unwrap_used)]
fn answer(f: &Fixture) -> Answer {
    match ops::remove(
        &f.env,
        &f.scope,
        &["github".into()],
        Some(ItemKind::Skill),
        false,
    ) {
        Ok(report) => {
            apply::execute(&f.env, &report.plan).unwrap();
            if manifest_of(f).is_suppressed(ItemKind::Skill, "github") {
                Answer::Suppressed
            } else {
                Answer::Removed
            }
        }
        Err(CoreError::RemovalProvenanceMissing {
            step: ProvenanceStep::Apply,
            ..
        }) => Answer::Missing,
        Err(CoreError::RemovalProvenanceMissing {
            step: ProvenanceStep::RetryReadable { .. },
            ..
        }) => Answer::Held,
        Err(_) => panic!("unexpected removal refusal"),
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn literal_v11_migrates_without_changing_offline_removal_answers() {
    for (name, rows, held, competing, declared, expected) in [
        (
            "withheld root",
            Some(ROOTED),
            false,
            false,
            true,
            Answer::Suppressed,
        ),
        (
            "captured empty",
            Some(EMPTY),
            false,
            false,
            false,
            Answer::Suppressed,
        ),
        ("unknown", None, false, false, false, Answer::Missing),
        ("held empty", Some(EMPTY), true, false, false, Answer::Held),
        (
            "competing full readings",
            Some(ROOTED),
            true,
            true,
            true,
            Answer::Suppressed,
        ),
    ] {
        for migrate in [false, true] {
            let f = fixture("[skills.github]\nsource = \"cat\"\n");
            apply_now(&f);
            let manifest_path = f.project.join("kendex.toml");
            let mut manifest = fs::read_to_string(&manifest_path).unwrap();
            // A surviving, unrelated declaration attempts the offline
            // catalog read even when no declaration roots dev itself.
            manifest.push_str("\n[skills.keeper]\nsource = \"cat\"\n");
            if declared {
                manifest.push_str("\n[skills.dev]\nsource = \"cat\"\n");
            }
            fs::write(&manifest_path, manifest).unwrap();
            let repo =
                serde_json::to_string(&lock_of(&f).entries["skill:github:claude"].source_repo)
                    .unwrap();
            let ancestry = rows.map_or_else(String::new, |row| {
                format!(",\"requirerProvenance\":{{\"rows\":[{row}],\"held\":{held}}}")
            });
            let other = if competing {
                format!(
                    r#", "skill:other:claude":{{"name":"other","kind":"skill","harness":"claude","source":"cat","sourceRepo":@repo@,"sourceHash":"abc","enabled":true,"reasons":[{{"reason":"requested"}}],"requirerProvenance":{{"rows":[{EMPTY}],"held":false}}}}"#
                )
            } else {
                String::new()
            };
            let text = V11
                .replace("@ancestry@", &ancestry)
                .replace("@other@", &other)
                .replace("@repo@", &repo);
            let path = lock_path(&f.env, &f.scope);
            fs::write(&path, &text).unwrap();
            fs::rename(&f.source, f.source.with_file_name("unavailable")).unwrap();
            let original = load_lock(&path).unwrap();
            assert_eq!(original.version, 11);
            assert_eq!(
                fs::read_to_string(&path).unwrap(),
                text,
                "read writes nothing"
            );
            if migrate {
                save(&path, &original).unwrap();
                let mut expected_lock = original;
                expected_lock.version = LOCK_VERSION;
                assert_eq!(load_lock(&path).unwrap(), expected_lock);
            }
            assert_eq!(answer(&f), expected, "{name} migrate={migrate}");
        }
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn authorized_scope_writes_migrate_v11_once_even_without_entries() {
    for (present, installed, has_manifest) in [
        (false, false, true),
        (true, false, true),
        (true, true, true),
        (true, false, false),
    ] {
        let f = fixture(if installed {
            "[skills.github]\nsource = \"cat\"\n"
        } else {
            ""
        });
        let path = lock_path(&f.env, &f.scope);
        if installed {
            apply_now(&f);
        }
        if present {
            if installed {
                let mut legacy = lock_of(&f);
                legacy.version = 11;
                for entry in legacy.entries.values_mut() {
                    for position in &mut entry.emitted.as_mut().unwrap().paths {
                        *position = position.strip_prefix(&f.project).unwrap().to_path_buf();
                    }
                }
                fs::write(&path, serde_json::to_string_pretty(&legacy).unwrap()).unwrap();
            } else {
                fs::write(&path, r#"{"version":11,"entries":{}}"#).unwrap();
            }
        }
        if !has_manifest {
            fs::remove_file(f.project.join("kendex.toml")).unwrap();
        }
        let before = fs::read(&path).ok();
        let report = audit(&f.env, &f.scope).unwrap();
        assert_eq!(fs::read(&path).ok(), before, "preview writes nothing");
        let writes = |report: &kendex_core::engine::EngineReport| {
            report
                .plan
                .ops
                .iter()
                .filter(|op| matches!(op.op, apply::Op::WriteLock { .. }))
                .count()
        };
        assert_eq!(writes(&report), usize::from(present && has_manifest));
        apply::execute(&f.env, &report.plan).unwrap();
        assert_eq!(
            load_lock(&path).unwrap().version,
            if has_manifest { LOCK_VERSION } else { 11 }
        );
        assert_eq!(writes(&audit(&f.env, &f.scope).unwrap()), 0);
    }
}
