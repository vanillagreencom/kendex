//! Adding a hook, command or MCP server by name from the reserved local
//! source. The local source is kendex's own authored area, laid out in
//! kendex's fixed dirs, so the add reads it as an explicit catalog and each
//! of these kinds resolves by name — the way a discovered third-party
//! repo's never do.
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::rooted;

use std::fs;

use kendex_core::engine::ops;
use kendex_core::env::{Env, FakeOs};
use kendex_core::manifest::LOCAL_SOURCE_NAME;
use kendex_core::model::{ItemKind, Scope};

const HOOK: &str = "#!/usr/bin/env bash\n# ---\n# name: audit\n# event: PreToolUse\n# matcher: Bash\n# description: log shell commands\n# timeout: 10\n# ---\nexit 0\n";
const COMMAND: &str = "---\ndescription: preview the site\n---\n\nRun the preview.\n";
const MCP: &str = "command = \"gh-mcp\"\nargs = [\"--stdio\"]\n";

/// Each executable kind at its fixed place in the local source, and the
/// request that names it.
#[test]
#[allow(clippy::unwrap_used)]
fn an_executable_kind_in_the_local_source_installs_by_name() {
    for (kind, file, body, request) in [
        (
            ItemKind::Hook,
            "hooks/audit.sh",
            HOOK,
            ops::AddRequest {
                hooks: vec!["audit".to_owned()],
                ..ops::AddRequest::default()
            },
        ),
        (
            ItemKind::Command,
            "commands/preview.md",
            COMMAND,
            ops::AddRequest {
                commands: vec!["preview".to_owned()],
                ..ops::AddRequest::default()
            },
        ),
        (
            ItemKind::McpServer,
            "mcp/gh.toml",
            MCP,
            ops::AddRequest {
                mcp_servers: vec!["gh".to_owned()],
                ..ops::AddRequest::default()
            },
        ),
    ] {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let env = Env::fake(&home, FakeOs::Linux);
        let project = home.join("app");
        fs::create_dir_all(project.join(".claude")).unwrap();
        fs::write(
            project.join("kendex.toml"),
            "schema = 6\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n",
        )
        .unwrap();
        let scope = Scope::Project {
            root: project.clone(),
        };
        let item = kendex_core::source::local_source_root(&env, &scope).join(file);
        fs::create_dir_all(item.parent().unwrap()).unwrap();
        fs::write(&item, body).unwrap();

        let report = ops::add(
            &env,
            &scope,
            &ops::AddRequest {
                source: Some(LOCAL_SOURCE_NAME.to_owned()),
                ..request
            },
        )
        .unwrap_or_else(|error| panic!("{} from local: {error}", kind.name()));
        kendex_core::apply::execute(&env, &report.plan).unwrap();
        let lock = kendex_core::lock::load(&kendex_core::lock::lock_path(&env, &scope)).unwrap();
        assert!(
            lock.entries
                .values()
                .any(|entry| entry.kind == kind && entry.source_repo == LOCAL_SOURCE_NAME),
            "{} is not installed from local: {:?}",
            kind.name(),
            lock.entries
        );
    }
}
