//! Removing OpenCode hooks retires generated settings and keeps user settings.

#[path = "../../test_util.rs"]
mod test_util;
use test_util::rooted;

use std::fs;

use kendex_core::apply::{self, Op};
use kendex_core::engine::{audit, ops};
use kendex_core::env::{Env, FakeOs};
use kendex_core::model::Scope;
use serde_json::json;

#[test]
#[allow(clippy::unwrap_used)]
fn hook_removal_trashes_generated_settings_and_preserves_user_keys() {
    for extra in [
        json!({}),
        json!({"theme": "personal"}),
        json!({"permission": {"bash": "deny"}}),
        json!({"instructions": ["AGENTS.md"]}),
    ] {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let env = Env::fake(&home, FakeOs::Linux);
        let root = home.join("project");
        fs::create_dir_all(root.join(".claude")).unwrap();
        fs::create_dir_all(root.join("catalog/hooks")).unwrap();
        fs::write(
            root.join("catalog/kendex.toml"),
            "is_source_catalog = true\n",
        )
        .unwrap();
        fs::write(root.join("catalog/hooks/guard.sh"), "#!/bin/sh\n# ---\n# name: guard\n# event: PreToolUse\n# matcher: Bash\n# description: check shell commands\n# ---\nexit 0\n").unwrap();
        fs::write(root.join("kendex.toml"), "schema = 6\n[sources.cat]\npath = \"catalog\"\n[install]\nharnesses = [\"opencode\"]\n[hooks.guard]\nsource = \"cat\"\n").unwrap();
        let scope = Scope::Project { root: root.clone() };
        apply::execute(&env, &audit(&env, &scope).unwrap().plan).unwrap();
        let config = root.join("opencode.json");
        let mut value: serde_json::Value =
            serde_json::from_str(&fs::read_to_string(&config).unwrap()).unwrap();
        assert_eq!(value["permission"]["bash"], json!({"*": "ask"}));
        for (key, content) in extra.as_object().unwrap() {
            if key == "instructions" {
                value[key]
                    .as_array_mut()
                    .unwrap()
                    .extend(content.as_array().unwrap().iter().cloned());
            } else {
                value[key] = content.clone();
            }
        }
        fs::write(&config, serde_json::to_string_pretty(&value).unwrap()).unwrap();
        let report = ops::remove(&env, &scope, &["guard".into()], None, false).unwrap();
        let empty = extra == json!({});
        assert_eq!(
            report
                .plan
                .ops
                .iter()
                .any(|op| matches!(&op.op, Op::Trash { path, .. } if path == &config)),
            empty
        );
        apply::execute(&env, &report.plan).unwrap();
        assert_eq!(config.exists(), !empty);
        assert!(
            !root
                .join(".opencode/instructions/kendex-hook-guard.md")
                .exists()
        );
        if !empty {
            let mut expected = extra;
            expected["$schema"] = json!("https://opencode.ai/config.json");
            let actual: serde_json::Value =
                serde_json::from_str(&fs::read_to_string(&config).unwrap()).unwrap();
            assert_eq!(actual, expected);
        }
    }
}
