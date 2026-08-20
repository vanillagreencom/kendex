use super::*;
use crate::env::FakeOs;

fn write(path: &Path, text: &str) {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).unwrap();
    }
    std::fs::write(path, text).unwrap();
}

/// A source package with one bin, one extension entry, an appendSystem file,
/// and a `node_modules` dir that must never be copied.
fn fixture(root: &Path, name: &str, guidance: &str) -> PathBuf {
    let dir = root.join("source/pi-extensions").join(name);
    write(
        &dir.join("package.json"),
        &format!(
            r#"{{
  "name": "{name}",
  "description": "does things",
  "version": "1.2.3",
  "pi": {{ "extensions": ["dist/index.js"], "appendSystem": "./system.md" }},
  "bin": "./cli.js"
}}"#
        ),
    );
    write(&dir.join("dist/index.js"), "export const x = 1;\n");
    write(&dir.join("cli.js"), "#!/usr/bin/env node\n");
    write(&dir.join("system.md"), guidance);
    write(&dir.join("node_modules/dep/index.js"), "junk\n");
    dir
}

fn settings_json(scope_root: &Path) -> Value {
    let text = std::fs::read_to_string(settings_path(scope_root)).unwrap();
    serde_json::from_str(&text).unwrap()
}

struct Fixture {
    _tmp: tempfile::TempDir,
    env: Env,
    root: PathBuf,
    scope: PathBuf,
}

fn scope() -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path().join("home"), FakeOs::Linux);
    let root = tmp.path().to_path_buf();
    let scope = root.join("proj/.pi");
    Fixture {
        _tmp: tmp,
        env,
        root,
        scope,
    }
}

#[test]
fn install_copies_registers_links_and_mirrors_append_system() {
    let f = scope();
    let source = fixture(&f.root, "pi-widgets", "Use the widget tool.\n");

    let outcome = install(&f.env, &f.scope, &source).unwrap();

    assert_eq!(outcome.version.as_deref(), Some("1.2.3"));
    assert!(outcome.unbuilt_bins.is_empty());
    assert!(f.scope.join("packages/pi-widgets/dist/index.js").is_file());
    assert!(!f.scope.join("packages/pi-widgets/node_modules").exists());
    assert_eq!(list_installed(&f.scope).unwrap(), ["pi-widgets"]);

    let link = f.scope.join("bin/pi-widgets");
    assert_eq!(outcome.bins, [f.scope.join("bin/pi-widgets")]);
    assert_eq!(
        std::fs::read_link(&link).unwrap(),
        f.scope.join("packages/pi-widgets/cli.js")
    );
    assert_eq!(
        settings_json(&f.scope)["packages"][0],
        "./packages/pi-widgets"
    );

    let append = std::fs::read_to_string(append_system_path(&f.scope)).unwrap();
    assert!(append.contains("<!-- kendex:append-system pi-widgets begin -->"));
    assert!(append.contains("Use the widget tool."));
}

#[test]
fn reinstalling_keeps_load_order_and_refreshes_the_append_system_block() {
    let f = scope();
    let first = fixture(&f.root, "pi-widgets", "Old guidance.\n");
    install(&f.env, &f.scope, &first).unwrap();
    let other = fixture(&f.root, "pi-other", "Other guidance.\n");
    install(&f.env, &f.scope, &other).unwrap();

    write(&first.join("system.md"), "New guidance.\n");
    write(&first.join("dist/index.js"), "export const x = 2;\n");
    install(&f.env, &f.scope, &first).unwrap();

    assert_eq!(
        settings_json(&f.scope)["packages"],
        serde_json::json!(["./packages/pi-widgets", "./packages/pi-other"])
    );
    let append = std::fs::read_to_string(append_system_path(&f.scope)).unwrap();
    assert!(append.contains("New guidance."));
    assert!(!append.contains("Old guidance."));
    assert!(append.contains("Other guidance."));
    assert_eq!(
        installed_hash(&f.scope, "pi-widgets").unwrap(),
        package_hash(&first).unwrap()
    );
}

#[test]
fn installed_hash_ignores_the_dependency_tree_and_reports_absence() {
    let f = scope();
    let source = fixture(&f.root, "pi-widgets", "Guidance.\n");
    install(&f.env, &f.scope, &source).unwrap();

    let installed = f.scope.join("packages/pi-widgets");
    write(&installed.join("node_modules/left-pad/index.js"), "dep\n");
    assert_eq!(
        installed_hash(&f.scope, "pi-widgets").unwrap(),
        package_hash(&source).unwrap()
    );

    write(&source.join("dist/index.js"), "export const x = 9;\n");
    assert_ne!(
        installed_hash(&f.scope, "pi-widgets").unwrap(),
        package_hash(&source).unwrap()
    );
    assert_eq!(installed_hash(&f.scope, "pi-absent").unwrap(), None);
}

#[test]
fn remove_leaves_no_trace_and_keeps_the_other_package() {
    let f = scope();
    let widgets = fixture(&f.root, "pi-widgets", "Widget guidance.\n");
    let other = fixture(&f.root, "pi-other", "Other guidance.\n");
    install(&f.env, &f.scope, &widgets).unwrap();
    install(&f.env, &f.scope, &other).unwrap();

    remove(&f.env, &f.scope, "pi-widgets").unwrap();

    assert!(!f.scope.join("packages/pi-widgets").exists());
    assert!(!f.scope.join("bin/pi-widgets").is_symlink());
    assert!(f.scope.join("bin/pi-other").is_symlink());
    assert_eq!(
        settings_json(&f.scope)["packages"],
        serde_json::json!(["./packages/pi-other"])
    );
    let append = std::fs::read_to_string(append_system_path(&f.scope)).unwrap();
    assert!(!append.contains("Widget guidance."));
    assert!(append.contains("Other guidance."));
    assert!(
        std::fs::read_dir(f.env.trash_dir())
            .unwrap()
            .flatten()
            .any(|entry| entry.path().join("package.json").is_file())
    );

    remove(&f.env, &f.scope, "pi-other").unwrap();
    assert!(!append_system_path(&f.scope).exists());
    assert!(settings_json(&f.scope).get("packages").is_none());
    assert!(list_installed(&f.scope).unwrap().is_empty());
    remove(&f.env, &f.scope, "pi-other").unwrap();
}

#[test]
fn scoped_packages_install_under_their_npm_scope() {
    let f = scope();
    let source = fixture(&f.root, "@vg/pi-hooks", "Hook guidance.\n");
    install(&f.env, &f.scope, &source).unwrap();

    assert!(f.scope.join("packages/@vg/pi-hooks/package.json").is_file());
    assert_eq!(list_installed(&f.scope).unwrap(), ["@vg/pi-hooks"]);
    assert_eq!(
        settings_json(&f.scope)["packages"][0],
        "./packages/@vg/pi-hooks"
    );
    assert!(f.scope.join("bin/@vg/pi-hooks").is_symlink());

    remove(&f.env, &f.scope, "@vg/pi-hooks").unwrap();
    assert!(!f.scope.join("bin/@vg/pi-hooks").is_symlink());
    assert!(!f.scope.join("packages/@vg/pi-hooks").exists());
}

#[test]
fn bin_forms_and_optional_fields_parse() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path().join("pkg");
    write(
        &dir.join("package.json"),
        r#"{"name": "pi-tools", "bin": {"widget": "./bin/widget.js", "gadget": "./bin/gadget.js"}}"#,
    );
    let package = read(&dir).unwrap();
    assert_eq!(
        package.bins,
        [
            ("gadget".to_owned(), "./bin/gadget.js".to_owned()),
            ("widget".to_owned(), "./bin/widget.js".to_owned()),
        ]
    );
    assert_eq!(package.description, None);
    assert_eq!(package.version, None);
    assert!(package.extensions.is_empty());
    assert_eq!(package.append_system, None);

    write(
        &dir.join("package.json"),
        r#"{"name": "pi-tools", "version": "0.1.0", "bin": "./cli.js",
            "pi": {"extensions": ["a.js", "b.js"], "appendSystem": "sys.md"}}"#,
    );
    let package = read(&dir).unwrap();
    assert_eq!(
        package.bins,
        [("pi-tools".to_owned(), "./cli.js".to_owned())]
    );
    assert_eq!(package.extensions, ["a.js", "b.js"]);
    assert_eq!(package.append_system.as_deref(), Some("sys.md"));
    assert!(read(&tmp.path().join("missing")).is_err());
}

#[test]
fn a_real_file_in_the_bin_dir_is_a_conflict_not_a_clobber_target() {
    let f = scope();
    let source = fixture(&f.root, "pi-widgets", "Guidance.\n");
    write(&f.scope.join("bin/pi-widgets"), "#!/bin/sh\necho mine\n");

    let error = install(&f.env, &f.scope, &source).unwrap_err();
    assert!(matches!(error, CoreError::PiPackage { .. }), "{error}");
    assert!(f.scope.join("bin/pi-widgets").is_file());
}

#[test]
fn a_bin_the_package_has_not_built_is_reported_not_linked() {
    let f = scope();
    let source = fixture(&f.root, "pi-widgets", "Guidance.\n");
    std::fs::remove_file(source.join("cli.js")).unwrap();

    let outcome = install(&f.env, &f.scope, &source).unwrap();
    assert_eq!(outcome.unbuilt_bins, ["pi-widgets"]);
    assert!(outcome.bins.is_empty());
    assert!(!f.scope.join("bin/pi-widgets").exists());
}

#[test]
fn a_package_without_an_append_system_file_writes_no_block() {
    let f = scope();
    let source = fixture(&f.root, "pi-widgets", "Guidance.\n");
    install(&f.env, &f.scope, &source).unwrap();
    assert!(append_system_path(&f.scope).exists());

    std::fs::remove_file(source.join("system.md")).unwrap();
    install(&f.env, &f.scope, &source).unwrap();
    assert!(!append_system_path(&f.scope).exists());
}

#[test]
#[cfg(unix)]
fn find_by_package_name_reads_sealed_and_skips_symlinked_metadata() {
    let tmp = tempfile::tempdir().unwrap();
    let base = tmp.path().canonicalize().unwrap().join("pi-extensions");
    write(
        &base.join("pi-hooks/package.json"),
        "{\"name\": \"@vg/pi-hooks\", \"version\": \"1.0.0\"}",
    );
    write(
        &base.join("@scope/pi-deep/package.json"),
        "{\"name\": \"@scope/pi-deep\", \"version\": \"1.0.0\"}",
    );
    // A hostile catalog linking metadata at host files must be skipped,
    // not followed.
    write(
        &tmp.path().join("outside.json"),
        "{\"name\": \"@vg/pi-evil\", \"version\": \"9.9.9\"}",
    );
    std::fs::create_dir_all(base.join("pi-evil")).unwrap();
    std::os::unix::fs::symlink(
        tmp.path().join("outside.json"),
        base.join("pi-evil/package.json"),
    )
    .unwrap();

    let sealed = crate::source_read::SealedSource::open(base.parent().unwrap()).unwrap();
    assert_eq!(
        find_by_package_name(&sealed, "@vg/pi-hooks").unwrap(),
        Some(base.join("pi-hooks"))
    );
    assert_eq!(
        find_by_package_name(&sealed, "@scope/pi-deep").unwrap(),
        Some(base.join("@scope/pi-deep"))
    );
    assert_eq!(find_by_package_name(&sealed, "@vg/pi-evil").unwrap(), None);
}

#[test]
fn find_by_package_name_refuses_an_ambiguous_registration() {
    let tmp = tempfile::tempdir().unwrap();
    let base = tmp.path().canonicalize().unwrap().join("pi-extensions");
    for dir in ["first", "second"] {
        write(
            &base.join(dir).join("package.json"),
            "{\"name\": \"@vg/pi-hooks\", \"version\": \"1.0.0\"}",
        );
    }
    let sealed = crate::source_read::SealedSource::open(base.parent().unwrap()).unwrap();
    let error = find_by_package_name(&sealed, "@vg/pi-hooks").unwrap_err();
    assert!(
        error.to_string().contains("refusing to pick one"),
        "{error}"
    );
}

/// A catalog whose `pi-extensions` is itself a symlink out of the catalog
/// must not have the escape laundered by sealing the folder as a root —
/// the traversal stays beneath the catalog's own seal and refuses the
/// link.
#[test]
#[cfg(unix)]
fn find_by_package_name_refuses_a_symlinked_extensions_folder() {
    let tmp = tempfile::tempdir().unwrap();
    let outside = tmp.path().canonicalize().unwrap().join("outside");
    write(
        &outside.join("pi-hooks/package.json"),
        "{\"name\": \"@vg/pi-hooks\", \"version\": \"9.9.9\"}",
    );
    let catalog = tmp.path().canonicalize().unwrap().join("catalog");
    std::fs::create_dir_all(&catalog).unwrap();
    std::os::unix::fs::symlink(&outside, catalog.join("pi-extensions")).unwrap();

    let sealed = crate::source_read::SealedSource::open(&catalog).unwrap();
    assert_eq!(find_by_package_name(&sealed, "@vg/pi-hooks").unwrap(), None);
}
