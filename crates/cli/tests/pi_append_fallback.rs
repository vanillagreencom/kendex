//! A trusted project's `.pi/APPEND_SYSTEM.md` holds inherited global
//! instructions only beside its own. Pi reads that file instead of the
//! global one, so an ordinary apply that leaves it nothing of its own takes
//! it away, and the user's global file applies again.

#![cfg(unix)]

use crate::test_util::{fixture_env, rooted, source_path};
use kendex_core::env::Env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

#[allow(clippy::unwrap_used, reason = "fixture process execution")]
fn kendex(home: &Path, project: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_kendex"))
        .args(args)
        .current_dir(project)
        .env_clear()
        .envs(fixture_env(home))
        .env("KENDEX_BACKGROUND_REFRESH", "off")
        .env("PATH", std::env::var_os("PATH").unwrap_or_default())
        .output()
        .unwrap()
}

fn ran(home: &Path, project: &Path, args: &[&str]) {
    let output = kendex(home, project, args);
    assert!(
        output.status.success(),
        "{args:?}: {}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}

#[allow(clippy::unwrap_used, reason = "fixture setup")]
fn write(path: &Path, text: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, text).unwrap();
}

/// What a project declares beside the source and harness lines.
enum Declares {
    Package { enabled: bool },
    Style,
    Nothing,
}

/// What the project's append file holds of its own before the change.
#[derive(Clone, Copy, Debug)]
enum Own {
    Nothing,
    Blank,
    Personal,
}

struct World {
    _temp: tempfile::TempDir,
    home: PathBuf,
    project: PathBuf,
    catalog: PathBuf,
    global_append: PathBuf,
    project_append: PathBuf,
}

impl World {
    #[allow(clippy::unwrap_used, reason = "fixture setup")]
    fn declare(&self, declares: &Declares) {
        let entry = match declares {
            Declares::Package { enabled } => {
                format!("[pi-extensions.local-tools]\nsource = \"cat\"\nenabled = {enabled}\n")
            }
            Declares::Style => "[output-styles.Local]\nsource = \"cat\"\n".to_owned(),
            Declares::Nothing => String::new(),
        };
        write(
            &self.project.join("kendex.toml"),
            &format!(
                "schema = 6\n[sources.cat]\n{}\n[install]\nharnesses = [\"pi\"]\n{entry}",
                source_path(&self.catalog)
            ),
        );
    }

    #[allow(clippy::unwrap_used, reason = "fixture inspection")]
    fn project_text(&self) -> Option<String> {
        self.project_append
            .exists()
            .then(|| fs::read_to_string(&self.project_append).unwrap())
    }
}

#[allow(clippy::unwrap_used, reason = "fixture setup")]
fn package(catalog: &Path, name: &str, guidance: &str) {
    let dir = catalog.join("pi-extensions").join(name);
    write(
        &dir.join("package.json"),
        &format!(
            r#"{{"name":"{name}","pi":{{"extensions":["index.js"],"appendSystem":"system.md"}}}}"#
        ),
    );
    write(
        &dir.join("index.js"),
        "export default function tools(pi) {}\n",
    );
    write(&dir.join("system.md"), guidance);
}

fn style(catalog: &Path, name: &str, body: &str) {
    write(
        &catalog.join("output-styles").join(format!("{name}.md")),
        &format!(
            "---\nname: {name}\ndescription: A style\nkeep-coding-instructions: true\n---\n{body}\n"
        ),
    );
}

/// A home whose global scope carries a package and a style, and a project
/// whose apply has written its own instructions beside the inherited ones,
/// then left as `own` says.
#[allow(clippy::unwrap_used, reason = "fixture setup and inspection")]
fn world(declares: &Declares, own: Own) -> World {
    let temp = tempfile::tempdir().unwrap();
    let home = rooted(&temp);
    let project = home.join("project");
    let catalog = home.join("catalog");
    fs::create_dir_all(project.join(".pi")).unwrap();
    write(&catalog.join("kendex.toml"), "is_source_catalog = true\n");
    package(&catalog, "global-tools", "Global tools.");
    package(&catalog, "local-tools", "Local tools.");
    style(&catalog, "Global", "Global style.");
    style(&catalog, "Local", "Local style.");
    let env = Env::host_rooted(&home);
    write(
        &env.global_manifest_file(),
        &format!(
            "schema = 6\n[sources.cat]\n{}\n[install]\nharnesses = [\"pi\"]\n[pi-extensions.global-tools]\nsource = \"cat\"\n[output-styles.Global]\nsource = \"cat\"\n",
            source_path(&catalog)
        ),
    );
    ran(&home, &project, &["update-pi", "--scope", "global"]);
    ran(&home, &project, &["apply", "--scope", "global", "--yes"]);
    let global_root =
        kendex_core::pi_ext::scope_root(&env, &kendex_core::model::Scope::Global).unwrap();
    let world = World {
        global_append: kendex_core::pi_ext::append_system_path(&global_root),
        project_append: project.join(".pi/APPEND_SYSTEM.md"),
        _temp: temp,
        home,
        project,
        catalog,
    };
    let global = fs::read_to_string(&world.global_append).unwrap();
    write(
        &world.global_append,
        &format!("Personal global instructions.\n{global}"),
    );
    world.declare(declares);
    if matches!(declares, Declares::Package { .. }) {
        ran(
            &world.home,
            &world.project,
            &["update-pi", "--scope", "project"],
        );
    }
    ran(
        &world.home,
        &world.project,
        &["apply", "--scope", "project", "--yes"],
    );
    let text = world.project_text().unwrap();
    for wanted in ["Local", "Global tools.", "Global style."] {
        assert!(text.contains(wanted), "{wanted}: {text}");
    }
    match own {
        Own::Nothing => (),
        Own::Blank => write(&world.project_append, ""),
        Own::Personal => write(
            &world.project_append,
            &format!("Personal project instructions.\n{text}"),
        ),
    }
    world
}

/// The project's own text survives, inherited text stays only beside it,
/// and one apply settles the file.
fn assert_fallback(world: &World, own: Own, row: &str) {
    let text = world.project_text();
    assert_eq!(
        text.is_some(),
        matches!(own, Own::Personal),
        "{row}: {text:?}"
    );
    let again = kendex(
        &world.home,
        &world.project,
        &["apply", "--plan", "--scope", "project"],
    );
    let said = format!(
        "{}{}",
        String::from_utf8_lossy(&again.stdout),
        String::from_utf8_lossy(&again.stderr)
    );
    assert!(said.contains("nothing to do"), "{row}: {said}");
    if let Some(text) = text {
        assert!(
            text.starts_with("Personal project instructions.\n"),
            "{row}: {text}"
        );
        assert!(text.contains("Global tools."), "{row}: {text}");
        assert!(!text.contains("Local"), "{row}: {text}");
    }
}

#[test]
#[allow(clippy::unwrap_used, reason = "fixture inspection")]
fn project_apply_leaves_no_project_file_holding_only_inherited_text() {
    for (declares, after, own) in [
        (
            Declares::Package { enabled: true },
            Declares::Package { enabled: false },
            Own::Nothing,
        ),
        (
            Declares::Package { enabled: true },
            Declares::Package { enabled: false },
            Own::Blank,
        ),
        (
            Declares::Package { enabled: true },
            Declares::Package { enabled: false },
            Own::Personal,
        ),
        (Declares::Style, Declares::Nothing, Own::Nothing),
        (Declares::Style, Declares::Nothing, Own::Blank),
        (Declares::Style, Declares::Nothing, Own::Personal),
    ] {
        let row = format!("style {}, {own:?}", matches!(declares, Declares::Style));
        let world = world(&declares, own);
        let global = fs::read(&world.global_append).unwrap();
        world.declare(&after);
        ran(
            &world.home,
            &world.project,
            &["apply", "--scope", "project", "--yes"],
        );
        assert_fallback(&world, own, &row);
        assert_eq!(fs::read(&world.global_append).unwrap(), global, "{row}");
        let check = kendex(
            &world.home,
            &world.project,
            &["verify", "--scope", "project"],
        );
        assert!(check.status.success(), "{row}: {check:?}");
    }
}

#[test]
#[allow(clippy::unwrap_used, reason = "fixture inspection")]
fn a_global_style_change_lands_with_the_last_project_package_removal() {
    for own in [Own::Nothing, Own::Personal] {
        let world = world(&Declares::Package { enabled: true }, own);
        style(&world.catalog, "Global", "Changed global style.");
        world.declare(&Declares::Nothing);
        ran(
            &world.home,
            &world.project,
            &["apply", "--scope", "all", "--yes"],
        );
        assert_fallback(&world, own, &format!("{own:?}"));
        let global = fs::read_to_string(&world.global_append).unwrap();
        assert!(
            global.starts_with("Personal global instructions.\n"),
            "{global}"
        );
        assert!(global.contains("Changed global style."), "{global}");
        if let Some(text) = world.project_text() {
            assert!(text.contains("Changed global style."), "{text}");
        }
        assert!(!world.project.join(".pi/packages/local-tools").exists());
    }
}
