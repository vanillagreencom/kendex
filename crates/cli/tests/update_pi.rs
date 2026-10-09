#![cfg(unix)]

use crate::test_util;
use test_util::rooted;

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process::{Command, Output};

use kendex_core::process::Hardened;

// Integration-test helpers sit outside #[test] fns, so clippy's
// allow-unwrap-in-tests does not reach them.
#[allow(clippy::expect_used)]
fn kendex(home: &Path, cwd: &Path, args: &[&str]) -> Output {
    kendex_command(home, cwd, args)
        .output()
        .expect("kendex binary runs")
}

#[allow(clippy::expect_used)]
fn kendex_command(home: &Path, cwd: &Path, args: &[&str]) -> Command {
    let mut paths = vec![home.join("bin")];
    paths.extend(std::env::split_paths(
        &std::env::var_os("PATH").unwrap_or_default(),
    ));
    let path = std::env::join_paths(paths).expect("fixture PATH joins");
    let mut command = Command::new(env!("CARGO_BIN_EXE_kendex"));
    command
        .args(args)
        .current_dir(cwd)
        .env_clear()
        .envs(test_util::fixture_env(home))
        .env("KENDEX_BACKGROUND_REFRESH", "off")
        .env(
            "KENDEX_GIT_BASE",
            format!("file://{}", home.join("git").display()),
        )
        .env("PATH", path);
    command
}

#[allow(clippy::unwrap_used)]
fn write(path: &Path, text: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, text).unwrap();
}

#[allow(clippy::unwrap_used)]
fn git(dir: &Path, args: &[&str]) {
    let output = Hardened::git(args, Some(dir)).run().unwrap();
    assert!(output.status.success(), "git {args:?}");
}

#[allow(clippy::unwrap_used)]
fn commit(dir: &Path, message: &str) -> String {
    git(dir, &["add", "-A"]);
    git(
        dir,
        &[
            "-c",
            "user.email=t@t",
            "-c",
            "user.name=t",
            "commit",
            "--quiet",
            "-m",
            message,
        ],
    );
    let output = Hardened::git(&["rev-parse", "HEAD"], Some(dir))
        .run()
        .unwrap();
    String::from_utf8_lossy(&output.stdout).trim().to_owned()
}

/// A project that declares one pi extension from a local catalog and already
/// has an older copy of it installed under `.pi/packages/`.
#[allow(clippy::unwrap_used)]
fn fixture() -> tempfile::TempDir {
    let tmp = tempfile::tempdir().unwrap();
    let project = tmp.path().join("dev/app");
    write(
        &project.join("kendex.toml"),
        "schema = 6\n\n[sources.cat]\npath = \"catalog\"\n\n[pi-extensions.pi-widgets]\nsource = \"cat\"\n",
    );
    let package = "{\n  \"name\": \"pi-widgets\",\n  \"version\": \"2.0.0\",\n  \"pi\": { \"extensions\": [\"index.js\"] }\n}\n";
    write(
        &project.join("catalog/pi-extensions/pi-widgets/package.json"),
        package,
    );
    write(
        &project.join("catalog/pi-extensions/pi-widgets/index.js"),
        "export const version = 2;\n",
    );

    write(
        &project.join(".pi/packages/pi-widgets/package.json"),
        package,
    );
    write(
        &project.join(".pi/packages/pi-widgets/index.js"),
        "export const version = 1;\n",
    );
    write(
        &project.join(".pi/settings.json"),
        "{\"packages\": [\"./packages/pi-widgets\"]}\n",
    );
    tmp
}

#[test]
fn check_reports_stale_packages_without_touching_them() {
    let tmp = fixture();
    let project = tmp.path().join("dev/app");
    let installed = project.join(".pi/packages/pi-widgets/index.js");

    let output = kendex(tmp.path(), &project, &["update-pi", "--check"]);

    assert!(output.status.success());
    let plan = String::from_utf8_lossy(&output.stdout);
    assert!(plan.contains("pi-widgets"), "{plan}");
    assert!(plan.contains("stale"), "{plan}");
    let summary = String::from_utf8_lossy(&output.stderr);
    assert!(summary.contains("1 package(s) can be updated"), "{summary}");
    assert_eq!(
        fs::read_to_string(&installed).unwrap(),
        "export const version = 1;\n"
    );
}

/// A local untracked package keeps its exact source identity. Changing only
/// CRLF to LF is still a source edit, so refresh settles the installed copy
/// instead of accepting its portable rendered identity as current source.
#[test]
#[allow(clippy::unwrap_used)]
fn refresh_settles_a_line_ending_edit_in_an_untracked_local_source() {
    let tmp = tempfile::tempdir().unwrap();
    let root = rooted(&tmp);
    let project = root.join("dev/app");
    write(
        &project.join("kendex.toml"),
        "schema = 6\n\n[sources.cat]\npath = \"catalog\"\n\n[pi-extensions.pi-widgets]\nsource = \"cat\"\n",
    );
    let source = project.join("catalog/pi-extensions/pi-widgets");
    write(
        &source.join("package.json"),
        "{\r\n  \"name\": \"pi-widgets\",\r\n  \"version\": \"1.0.0\",\r\n  \"pi\": { \"extensions\": [\"index.js\"] }\r\n}\r\n",
    );
    write(&source.join("index.js"), "export const version = 1;\r\n");
    git(&project, &["init", "-q", "-b", "main"]);
    git(&project, &["config", "core.autocrlf", "true"]);

    let installed = kendex(&root, &project, &["update-pi", "--scope", "project"]);
    assert!(installed.status.success(), "{installed:?}");
    let destination = project.join(".pi/packages/pi-widgets/index.js");
    assert!(fs::read(&destination).unwrap().contains(&b'\r'));

    write(&source.join("index.js"), "export const version = 1;\n");
    let package = fs::read_to_string(source.join("package.json"))
        .unwrap()
        .replace("\r\n", "\n");
    write(&source.join("package.json"), &package);
    let refreshed = kendex(
        &root,
        &project,
        &["refresh", "--scope", "project", "--yes", "--leave"],
    );

    assert!(refreshed.status.success(), "{refreshed:?}");
    assert!(!fs::read(&destination).unwrap().contains(&b'\r'));
}

/// The replaced copy goes to the trash, and the run closes on the trash
/// pass: an entry past the default age bound goes, the copy this run
/// moved aside stays.
#[test]
fn update_reinstalls_from_the_declared_source() {
    let tmp = fixture();
    let project = tmp.path().join("dev/app");
    let installed = project.join(".pi/packages/pi-widgets/index.js");
    let trash = kendex_core::env::Env::host_rooted(tmp.path()).trash_dir();
    let stale = trash.join(format!(
        "{}-stale",
        kendex_core::clock::iso_from_unix(kendex_core::clock::unix_now() - 40 * 86_400)
            .replace(':', "-")
    ));
    fs::create_dir_all(&stale).unwrap();

    let output = kendex(tmp.path(), &project, &["update-pi"]);

    assert!(output.status.success());
    let progress = String::from_utf8_lossy(&output.stdout);
    assert!(
        progress.contains("updated pi-widgets -> 2.0.0"),
        "{progress}"
    );
    assert_eq!(
        fs::read_to_string(&installed).unwrap(),
        "export const version = 2;\n"
    );
    let said = String::from_utf8_lossy(&output.stderr);
    // Said before the line the run closes on.
    let pass = said.find("trash: removed 1 older entry");
    let closing = said.find("updated 1 package(s)");
    assert!(
        matches!((pass, closing), (Some(pass), Some(closing)) if pass < closing),
        "{said}"
    );
    assert!(!stale.exists());
    let held: Vec<String> = fs::read_dir(&trash)
        .unwrap()
        .flatten()
        .map(|entry| entry.file_name().to_string_lossy().into_owned())
        .collect();
    assert!(
        held.iter().any(|name| name.ends_with("-pi-widgets")),
        "the replaced copy is gone: {held:?}"
    );

    // A second run has nothing left to do.
    let output = kendex(tmp.path(), &project, &["update-pi"]);
    assert!(output.status.success());
    let summary = String::from_utf8_lossy(&output.stderr);
    assert!(summary.contains("all pi packages up to date"), "{summary}");
}

#[test]
#[allow(clippy::unwrap_used)]
fn an_npm_failure_records_only_the_sibling_whose_install_completed() {
    for failure in ["first", "upgrade", "missing"] {
        let upgrade = failure != "first";
        let tmp = tempfile::tempdir().unwrap();
        let root = rooted(&tmp);
        let project = root.join("dev/app");
        write(
            &project.join("kendex.toml"),
            "schema = 6\n[sources.cat]\npath = \"catalog\"\n[pi-extensions.bad]\nsource = \"cat\"\n[pi-extensions.good]\nsource = \"cat\"\n",
        );
        write(
            &project.join("catalog/pi-extensions/good/package.json"),
            r#"{"name":"good","version":"1.0.0"}"#,
        );
        write(
            &project.join("catalog/pi-extensions/good/index.js"),
            "export const good = true;\n",
        );
        write(
            &project.join("catalog/pi-extensions/bad/package.json"),
            r#"{"name":"bad","version":"1.0.0","dependencies":{"dep":"1.0.0"}}"#,
        );
        let source = project.join("catalog/pi-extensions/bad/index.js");
        write(&source, "export const version = 1;\n");
        let npm = root.join("bin/npm");
        write(&npm, "#!/bin/sh\nexit 0\n");
        fs::set_permissions(&npm, fs::Permissions::from_mode(0o755)).unwrap();
        fs::create_dir_all(project.join(".pi")).unwrap();
        let lock_path = project.join(".kendex-lock.json");
        let key = kendex_core::lock::entry_key(
            kendex_core::model::ItemKind::PiExtension,
            "bad",
            kendex_core::model::HarnessId::Pi,
        );
        let mut completed = if upgrade {
            assert!(
                kendex(&root, &project, &["update-pi", "--scope", "project"])
                    .status
                    .success()
            );
            kendex_core::lock::load(&lock_path)
                .unwrap()
                .entries
                .get(&key)
                .cloned()
        } else {
            None
        };
        if failure == "missing" {
            fs::remove_dir_all(project.join(".pi/packages/bad")).unwrap();
        } else {
            write(&source, "export const version = 2;\n");
        }
        if let Some(entry) = &mut completed {
            entry.rendered_hash = None;
        }
        write(&npm, "#!/bin/sh\nexit 1\n");
        for _ in 0..2 {
            let output = kendex(&root, &project, &["update-pi", "--scope", "project"]);
            assert!(!output.status.success(), "upgrade={upgrade}: {output:?}");
            assert_eq!(
                fs::read(project.join(".pi/packages/bad/index.js")).unwrap(),
                fs::read(&source).unwrap(),
                "npm fails after source files are copied"
            );
            let check = kendex(&root, &project, &["check", "--scope", "project"]);
            assert_eq!(check.status.code(), Some(1), "{check:?}");
            assert!(
                String::from_utf8_lossy(&check.stdout).contains("kendex update-pi --scope project"),
                "{check:?}"
            );
            let updates = kendex(&root, &project, &["updates"]);
            assert!(
                String::from_utf8_lossy(&updates.stderr).contains("pi-extension bad"),
                "{updates:?}"
            );
            let refresh = kendex(&root, &project, &["refresh", "--scope", "project", "--yes"]);
            // An unrecorded matching copy is eligible but needs npm. Recorded
            // incomplete installs still fail. Retaining process-only drift is
            // the must-fail control for the first-install row.
            assert_eq!(refresh.status.success(), !upgrade, "{refresh:?}");
            assert_eq!(
                kendex_core::lock::load(&lock_path)
                    .unwrap()
                    .entries
                    .get(&key),
                completed.as_ref(),
                "failed installs preserve provenance without completion"
            );
            let check = kendex(&root, &project, &["check", "--scope", "project"]);
            assert_eq!(check.status.code(), Some(1), "{check:?}");
            let verify = kendex(&root, &project, &["verify", "--scope", "project"]);
            assert!(!verify.status.success(), "{verify:?}");
        }
        let settings = fs::read_to_string(project.join(".pi/settings.json")).unwrap();
        assert!(settings.contains("./packages/good"), "{settings}");
        assert_eq!(settings.contains("./packages/bad"), upgrade, "{settings}");
        write(&npm, "#!/bin/sh\nexit 0\n");
        let repaired = kendex(&root, &project, &["update-pi", "--scope", "project"]);
        assert!(repaired.status.success(), "{repaired:?}");
        assert_npm_repaired(&root, &project);
    }
}

/// Real npm resolves only this registry. The broken dev release reproduces
/// the producer in KEN-3607; the unlocked row also proves its ETARGET cause.
#[test]
#[allow(clippy::unwrap_used)]
fn npm_installs_the_locked_runtime_tree_without_resolving_new_dev_releases() {
    use npm_registry::Row;
    let tmp = tempfile::tempdir().unwrap();
    let root = rooted(&tmp);
    let registry = npm_registry::Registry::new(&root);
    for row in [
        Row::Locked,
        Row::Unlocked,
        Row::StaleLock,
        Row::BrokenUnlocked,
    ] {
        let project = root.join(format!("dev/{row:?}"));
        let source = registry.source(&project, row);
        let output = registry.run(&root, &project);
        npm_registry::assert_result(
            row,
            &output,
            &source,
            &project.join(".pi/packages/pi-widgets"),
        );
        if output.status.success() {
            let second = registry.run(&root, &project);
            assert!(second.status.success());
            assert!(String::from_utf8_lossy(&second.stderr).contains("all pi packages up to date"));
        }
    }
}

#[allow(clippy::unwrap_used, clippy::expect_used)]
mod npm_registry {
    use super::*;
    use serde_json::{Value, json};
    use std::collections::BTreeMap;
    use std::io::{BufRead, BufReader, Write};
    use std::net::{SocketAddr, TcpListener, TcpStream};
    use std::thread::{self, JoinHandle};
    use std::time::Duration;

    pub(super) struct Registry {
        address: SocketAddr,
        worker: Option<JoinHandle<()>>,
        environment: Vec<(&'static str, String)>,
        packuments: BTreeMap<String, Value>,
    }

    impl Drop for Registry {
        fn drop(&mut self) {
            let shutdown = TcpStream::connect(self.address)
                .and_then(|mut connection| connection.write_all(b"GET /shutdown HTTP/1.1\r\n\r\n"));
            let result = self.worker.take().unwrap().join();
            if !thread::panicking() {
                shutdown.expect("registry shutdown sent");
                result.expect("registry worker completed");
            }
        }
    }

    impl Registry {
        pub(super) fn new(root: &Path) -> Self {
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            let address = listener.local_addr().unwrap();
            let registry_url = format!("http://{address}");
            let userconfig = root.join("npmrc");
            write(&userconfig, "");
            let npm_environment = vec![
                ("npm_config_registry", registry_url.clone()),
                (
                    "npm_config_cache",
                    root.join("npm-cache").display().to_string(),
                ),
                ("npm_config_userconfig", userconfig.display().to_string()),
                (
                    "npm_config_globalconfig",
                    root.join("global-npmrc").display().to_string(),
                ),
                ("npm_config_fetch_retries", "0".to_owned()),
                ("npm_config_fetch_timeout", "1000".to_owned()),
            ];
            let (packuments, responses) = pack(root, &registry_url, &npm_environment);
            Self {
                address,
                worker: Some(serve(listener, responses)),
                environment: npm_environment,
                packuments,
            }
        }

        pub(super) fn source(&self, project: &Path, row: Row) -> std::path::PathBuf {
            let source = project.join("catalog/pi-extensions/pi-widgets");
            write(
                &project.join("kendex.toml"),
                "schema = 6\n[sources.cat]\npath = \"catalog\"\n[pi-extensions.pi-widgets]\nsource = \"cat\"\n",
            );
            let mut manifest = json!({
                "name": "pi-widgets", "version": "1.0.0",
                "dependencies": {"dep": "^1.0.0"},
                "devDependencies": {"devtool": "^1.0.0", "peer": "^1.0.0"},
                "peerDependencies": {"peer": "^1.0.0"},
                "peerDependenciesMeta": {"peer": {"optional": true}},
                "pi": {"extensions": ["index.js"]},
            });
            let mut packages = json!({"": manifest.clone()});
            for name in ["dep", "devtool", "peer"] {
                let package = &self.packuments[name]["versions"]["1.0.0"];
                let mut entry = json!({
                    "version": "1.0.0", "resolved": package["dist"]["tarball"],
                    "integrity": package["dist"]["integrity"],
                });
                if name != "dep" {
                    entry["dev"] = json!(true);
                }
                packages[format!("node_modules/{name}")] = entry;
            }
            let lock = json!({
                "name": "pi-widgets", "version": "1.0.0", "lockfileVersion": 3,
                "requires": true, "packages": packages,
            });
            match row {
                Row::Locked => write(&source.join("package-lock.json"), &lock.to_string()),
                Row::StaleLock => {
                    write(&source.join("package-lock.json"), &lock.to_string());
                    manifest["dependencies"]["dep"] = json!("^1.1.0");
                }
                Row::Unlocked => {
                    manifest["devDependencies"]
                        .as_object_mut()
                        .unwrap()
                        .remove("devtool");
                }
                Row::BrokenUnlocked => {}
            }
            write(&source.join("package.json"), &manifest.to_string());
            write(&source.join("index.js"), "export const version = 1;\n");
            source
        }

        pub(super) fn run(&self, root: &Path, project: &Path) -> Output {
            kendex_command(root, project, &["update-pi", "--scope", "project"])
                .envs(self.environment.iter().map(|(key, value)| (*key, value)))
                .output()
                .unwrap()
        }
    }

    fn pack(
        root: &Path,
        registry_url: &str,
        npm_environment: &[(&str, String)],
    ) -> (BTreeMap<String, Value>, BTreeMap<String, Vec<u8>>) {
        let mut packuments = BTreeMap::<String, Value>::new();
        let mut responses = BTreeMap::<String, Vec<u8>>::new();
        for (name, version, dependencies) in [
            ("dep", "1.0.0", json!({})),
            ("dep", "1.1.0", json!({})),
            ("devtool", "1.0.0", json!({})),
            ("devtool", "1.1.0", json!({"gone": "^2.0.0"})),
            ("gone", "1.0.0", json!({})),
            ("peer", "1.0.0", json!({})),
        ] {
            let directory = root.join(format!("packed/{name}-{version}"));
            let mut manifest =
                json!({"name": name, "version": version, "dependencies": dependencies});
            write(&directory.join("package.json"), &manifest.to_string());
            let packed = Command::new("npm")
                .args(["pack", "--json", "--ignore-scripts", "--offline"])
                .current_dir(&directory)
                .env_clear()
                .envs(test_util::fixture_env(root))
                .env("PATH", std::env::var_os("PATH").unwrap())
                .envs(npm_environment.iter().map(|(key, value)| (*key, value)))
                .output()
                .expect("real npm is required for the registry fixture");
            assert!(
                packed.status.success(),
                "{}",
                String::from_utf8_lossy(&packed.stderr)
            );
            let metadata: Value = serde_json::from_slice(&packed.stdout).unwrap();
            let filename = metadata[0]["filename"].as_str().unwrap();
            let route = format!("/{name}/-/{filename}");
            manifest["dist"] = json!({
                "tarball": format!("{registry_url}{route}"),
                "integrity": metadata[0]["integrity"],
            });
            responses.insert(route, fs::read(directory.join(filename)).unwrap());
            let packument = packuments
                .entry(name.to_owned())
                .or_insert_with(|| json!({"name": name, "dist-tags": {}, "versions": {}}));
            packument["dist-tags"]["latest"] = json!(version);
            packument["versions"][version] = manifest;
        }
        for (name, packument) in &packuments {
            responses.insert(format!("/{name}"), serde_json::to_vec(packument).unwrap());
        }
        (packuments, responses)
    }

    fn serve(listener: TcpListener, responses: BTreeMap<String, Vec<u8>>) -> JoinHandle<()> {
        thread::spawn(move || {
            for connection in listener.incoming() {
                let mut connection = connection.unwrap();
                connection
                    .set_read_timeout(Some(Duration::from_secs(10)))
                    .unwrap();
                connection
                    .set_write_timeout(Some(Duration::from_secs(10)))
                    .unwrap();
                let mut reader = BufReader::new(&connection);
                let mut request = String::new();
                if reader.read_line(&mut request).unwrap() == 0 {
                    continue;
                }
                let route = request.split_whitespace().nth(1).unwrap();
                if route == "/shutdown" {
                    break;
                }
                loop {
                    let mut header = String::new();
                    if reader.read_line(&mut header).unwrap() == 0 || header == "\r\n" {
                        break;
                    }
                }
                let missing = br#"{"error":"not_found"}"#;
                let (status, body) = match responses.get(route) {
                    Some(body) => ("200 OK", body.as_slice()),
                    None => ("404 Not Found", missing.as_slice()),
                };
                let headers = format!(
                    "HTTP/1.1 {status}\r\nContent-Type: {}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                    if route.ends_with(".tgz") {
                        "application/octet-stream"
                    } else {
                        "application/json"
                    },
                    body.len()
                );
                if let Err(error) = connection
                    .write_all(headers.as_bytes())
                    .and_then(|()| connection.write_all(body))
                {
                    // npm cancels requests for dependencies it omits.
                    assert!(matches!(
                        error.kind(),
                        std::io::ErrorKind::BrokenPipe | std::io::ErrorKind::ConnectionReset
                    ));
                }
            }
        })
    }

    #[derive(Clone, Copy, Debug)]
    pub(super) enum Row {
        Locked,
        Unlocked,
        StaleLock,
        BrokenUnlocked,
    }
    pub(super) fn assert_result(row: Row, output: &Output, source: &Path, installed: &Path) {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let modules = installed.join("node_modules");
        match row {
            Row::Locked | Row::Unlocked => {
                assert!(output.status.success(), "{row:?}: {stderr}");
                let dependency: Value =
                    serde_json::from_slice(&fs::read(modules.join("dep/package.json")).unwrap())
                        .unwrap();
                assert_eq!(
                    dependency["version"],
                    match row {
                        Row::Locked => "1.0.0",
                        Row::Unlocked => "1.1.0",
                        Row::StaleLock | Row::BrokenUnlocked => unreachable!(),
                    }
                );
                assert!(!modules.join("devtool").exists(), "{row:?}");
                assert!(!modules.join("peer").exists(), "{row:?}");
                if matches!(row, Row::Locked) {
                    assert_eq!(
                        fs::read(installed.join("package-lock.json")).unwrap(),
                        fs::read(source.join("package-lock.json")).unwrap()
                    );
                } else {
                    assert!(!installed.join("package-lock.json").exists());
                }
            }
            Row::StaleLock | Row::BrokenUnlocked => {
                assert!(!output.status.success(), "{row:?}");
                assert!(
                    !modules.join("dep").exists(),
                    "{row:?}: a fresh install followed failure"
                );
                // The issue explicitly requires the human recovery command to
                // identify the operation that failed.
                let recovery = match row {
                    Row::StaleLock => {
                        assert!(stderr.contains("EUSAGE"), "{stderr}");
                        assert!(
                            stderr.contains(
                                "Invalid: lock file's dep@1.0.0 does not satisfy dep@1.1.0"
                            ),
                            "{stderr}"
                        );
                        "ci --omit=dev --legacy-peer-deps --no-audit --no-fund"
                    }
                    Row::BrokenUnlocked => {
                        assert!(stderr.contains("ETARGET"), "{stderr}");
                        assert!(stderr.contains("gone@^2.0.0"), "{stderr}");
                        "install --omit=dev --package-lock=false --legacy-peer-deps --no-audit --no-fund"
                    }
                    Row::Locked | Row::Unlocked => unreachable!(),
                };
                assert!(
                    stderr.contains(&format!(
                        "Recovery: `cd '{}' && npm {recovery}`",
                        installed.display()
                    )),
                    "{stderr}"
                );
            }
        }
    }
}

#[allow(clippy::unwrap_used)]
fn assert_npm_repaired(home: &Path, project: &Path) {
    let check = kendex(home, project, &["check", "--scope", "project"]);
    assert_eq!(check.status.code(), Some(0), "{check:?}");
    assert!(
        fs::read_to_string(project.join(".pi/settings.json"))
            .unwrap()
            .contains("./packages/bad")
    );
    let verify = kendex(home, project, &["verify", "--scope", "project"]);
    assert!(verify.status.success(), "{verify:?}");
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_pinned_pi_extension_installs_and_verifies_against_its_revision() {
    let tmp = tempfile::tempdir().unwrap();
    let root = rooted(&tmp);
    let project = root.join("dev/app");
    let upstream = root.join("git/owner/catalog");
    write(
        &upstream.join("pi-extensions/pi-widgets/package.json"),
        "{\"name\":\"pi-widgets\",\"version\":\"1.0.0\"}\n",
    );
    write(
        &upstream.join("pi-extensions/pi-widgets/index.js"),
        "export const version = 1;\n",
    );
    git(&upstream, &["init", "--quiet", "-b", "main"]);
    let pinned = commit(&upstream, "one");
    write(
        &upstream.join("pi-extensions/pi-widgets/package.json"),
        "{\"name\":\"pi-widgets\",\"version\":\"2.0.0\"}\n",
    );
    write(
        &upstream.join("pi-extensions/pi-widgets/index.js"),
        "export const version = 2;\n",
    );
    commit(&upstream, "two");
    write(
        &project.join("kendex.toml"),
        &format!(
            "schema = 6\n\n[sources.cat]\nrepo = \"owner/catalog\"\n\n[pi-extensions.pi-widgets]\nsource = \"cat\"\nrev = \"{pinned}\"\n"
        ),
    );
    fs::create_dir_all(project.join(".pi")).unwrap();
    let refresh = kendex(&root, &project, &["refresh", "--scope", "project", "--yes"]);
    assert!(
        refresh.status.success(),
        "{}",
        String::from_utf8_lossy(&refresh.stderr)
    );
    assert_eq!(
        fs::read_to_string(project.join(".pi/packages/pi-widgets/index.js")).unwrap(),
        "export const version = 1;\n"
    );
    let lock = kendex_core::lock::load(&project.join(".kendex-lock.json")).unwrap();
    let recorded = lock
        .entries
        .values()
        .find(|entry| entry.name == "pi-widgets")
        .unwrap();
    assert_eq!(recorded.source_commit.as_deref(), Some(pinned.as_str()));
    let verify = kendex(&root, &project, &["verify", "--scope", "project"]);
    assert!(
        verify.status.success(),
        "{}",
        String::from_utf8_lossy(&verify.stderr)
    );
    let updates = kendex(&root, &project, &["updates"]);
    assert!(updates.status.success());
    let text = String::from_utf8_lossy(&updates.stderr);
    assert!(
        text.contains("pi-extension pi-widgets") && text.contains("[held]"),
        "{text}"
    );
    let preview = kendex(
        &root,
        &project,
        &["update-pi", "--check", "--scope", "project"],
    );
    let text = String::from_utf8_lossy(&preview.stdout);
    assert!(
        preview.status.success() && text.contains("up to date"),
        "{preview:?}"
    );
    assert_eq!(
        fs::read_to_string(project.join(".pi/packages/pi-widgets/index.js")).unwrap(),
        "export const version = 1;\n"
    );
    let checked = kendex(&root, &project, &["check", "--scope", "project"]);
    assert_eq!(checked.status.code(), Some(0), "{checked:?}");
}

#[test]
fn verification_and_record_recovery_compare_pi_bytes() {
    let tmp = fixture();
    let project = tmp.path().join("dev/app");
    assert!(
        kendex(tmp.path(), &project, &["update-pi"])
            .status
            .success()
    );
    assert!(
        kendex(tmp.path(), &project, &["verify", "--scope", "project"])
            .status
            .success()
    );
    fs::remove_file(project.join(".kendex-lock.json")).unwrap();
    let recovered = kendex(
        tmp.path(),
        &project,
        &["apply", "--record-existing", "--yes"],
    );
    assert!(recovered.status.success(), "{recovered:?}");
    assert!(
        kendex(tmp.path(), &project, &["verify", "--scope", "project"])
            .status
            .success()
    );
    let installed = project.join(".pi/packages/pi-widgets/index.js");
    fs::write(&installed, "export const version = 9;\n").unwrap();
    assert!(
        !kendex(tmp.path(), &project, &["verify", "--scope", "project"])
            .status
            .success()
    );
    fs::remove_file(project.join(".kendex-lock.json")).unwrap();
    assert!(
        !kendex(
            tmp.path(),
            &project,
            &["apply", "--record-existing", "--yes"]
        )
        .status
        .success()
    );
    let refresh = kendex(
        tmp.path(),
        &project,
        &["refresh", "--scope", "project", "--yes"],
    );
    assert!(!refresh.status.success(), "{refresh:?}");
    assert_eq!(
        fs::read_to_string(&installed).unwrap(),
        "export const version = 9;\n"
    );
    // The refresh wrote the scope's record for what it planned; the edited
    // package is not in it, and the recovery below starts lockless again.
    let lock = kendex_core::lock::load(&project.join(".kendex-lock.json")).unwrap();
    assert!(
        !lock
            .entries
            .values()
            .any(|entry| entry.name == "pi-widgets")
    );
    fs::remove_file(project.join(".kendex-lock.json")).unwrap();
    fs::remove_dir_all(project.join(".pi/packages/pi-widgets")).unwrap();
    assert!(
        !kendex(
            tmp.path(),
            &project,
            &["apply", "--record-existing", "--yes"]
        )
        .status
        .success()
    );
    assert!(!project.join(".kendex-lock.json").exists());
}

#[test]
fn a_busy_scope_refuses_pi_mutation() {
    let tmp = fixture();
    let project = tmp.path().join("dev/app");
    let env = kendex_core::env::Env::host_rooted(tmp.path());
    let scope = kendex_core::model::Scope::Project {
        root: project.clone(),
    };
    let guard = kendex_core::apply::lock_scope(&env, &scope).unwrap();
    let output = kendex(tmp.path(), &project, &["update-pi"]);
    assert!(!output.status.success(), "{output:?}");
    assert_eq!(
        fs::read_to_string(project.join(".pi/packages/pi-widgets/index.js")).unwrap(),
        "export const version = 1;\n"
    );
    drop(guard);
    assert!(
        kendex(tmp.path(), &project, &["update-pi"])
            .status
            .success()
    );
}

#[test]
fn changing_pi_source_refuses_before_package_mutation() {
    let tmp = fixture();
    let project = tmp.path().join("dev/app");
    assert!(
        kendex(tmp.path(), &project, &["update-pi"])
            .status
            .success()
    );
    let lock = fs::read(project.join(".kendex-lock.json")).unwrap();
    fs::rename(project.join("catalog"), project.join("other-catalog")).unwrap();
    let manifest = project.join("kendex.toml");
    fs::write(
        &manifest,
        fs::read_to_string(&manifest)
            .unwrap()
            .replace("\"catalog\"", "\"other-catalog\""),
    )
    .unwrap();
    fs::write(
        project.join("other-catalog/pi-extensions/pi-widgets/index.js"),
        "export const version = 3;\n",
    )
    .unwrap();
    let preview = kendex(tmp.path(), &project, &["update-pi", "--check"]);
    assert!(!preview.status.success(), "{preview:?}");
    assert!(!String::from_utf8_lossy(&preview.stderr).contains("run without --check"));
    assert!(
        !kendex(tmp.path(), &project, &["update-pi"])
            .status
            .success()
    );
    assert_eq!(fs::read(project.join(".kendex-lock.json")).unwrap(), lock);
    assert_eq!(
        fs::read_to_string(project.join(".pi/packages/pi-widgets/index.js")).unwrap(),
        "export const version = 2;\n"
    );
}

/// Nothing of the package is left behind: no settings entry, no package
/// directory, no record.
#[allow(clippy::unwrap_used)]
fn assert_pi_widgets_gone(project: &Path) {
    assert!(!project.join(".pi/packages/pi-widgets").exists());
    let settings = fs::read_to_string(project.join(".pi/settings.json")).unwrap();
    assert!(!settings.contains("pi-widgets"), "{settings}");
    let lock = kendex_core::lock::load(&project.join(".kendex-lock.json")).unwrap();
    assert!(
        !lock
            .entries
            .values()
            .any(|entry| entry.name == "pi-widgets")
    );
}

#[test]
fn orphan_cleanup_takes_the_pi_package_its_registration_and_its_record_together() {
    let tmp = fixture();
    let project = tmp.path().join("dev/app");
    assert!(
        kendex(tmp.path(), &project, &["update-pi"])
            .status
            .success()
    );
    fs::write(project.join("kendex.toml"), "schema = 6\n").unwrap();
    // Refresh keeps and reports orphaned Pi packages without refusing
    // the scope over them.
    let refresh = kendex(
        tmp.path(),
        &project,
        &["refresh", "--scope", "project", "--yes", "--leave"],
    );
    assert!(refresh.status.success(), "{refresh:?}");
    let env = kendex_core::env::Env::host_rooted(tmp.path());
    let scope = kendex_core::model::Scope::Project {
        root: project.clone(),
    };
    let options = kendex_core::engine::PlanOptions {
        remove_orphans: true,
        ..kendex_core::engine::PlanOptions::current()
    };
    let report = kendex_core::engine::plan_apply(&env, &scope, &options).unwrap();
    kendex_core::apply::execute(&env, &report.plan).unwrap();
    assert_pi_widgets_gone(&project);
}

#[test]
fn remove_takes_a_declared_pi_extension_with_its_declaration() {
    let tmp = fixture();
    let project = tmp.path().join("dev/app");
    assert!(
        kendex(tmp.path(), &project, &["update-pi"])
            .status
            .success()
    );
    let output = kendex(
        tmp.path(),
        &project,
        &[
            "remove",
            "pi-widgets",
            "--scope",
            "project",
            "--no-sweep",
            "--leave",
        ],
    );
    assert!(output.status.success(), "{output:?}");
    let manifest = fs::read_to_string(project.join("kendex.toml")).unwrap();
    assert!(!manifest.contains("pi-widgets"), "{manifest}");
    assert_pi_widgets_gone(&project);
}

#[test]
#[allow(clippy::unwrap_used)]
fn an_unreadable_lock_refuses_before_a_package_changes() {
    let tmp = fixture();
    let project = tmp.path().join("dev/app");
    let installed = project.join(".pi/packages/pi-widgets/index.js");
    fs::write(project.join(".kendex-lock.json"), "{\"version\":5}\n").unwrap();

    let output = kendex(tmp.path(), &project, &["update-pi"]);

    assert!(!output.status.success());
    assert_eq!(
        fs::read_to_string(installed).unwrap(),
        "export const version = 1;\n"
    );
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_declared_package_not_yet_installed_installs_fresh() {
    let tmp = fixture();
    let project = tmp.path().join("dev/app");
    fs::remove_dir_all(project.join(".pi/packages/pi-widgets")).unwrap();
    fs::write(project.join(".pi/settings.json"), "{}\n").unwrap();

    let check = kendex(tmp.path(), &project, &["update-pi", "--check"]);
    assert!(check.status.success());
    let plan = String::from_utf8_lossy(&check.stdout);
    assert!(plan.contains("not installed yet"), "{plan}");

    let output = kendex(tmp.path(), &project, &["update-pi"]);
    assert!(output.status.success());
    let progress = String::from_utf8_lossy(&output.stdout);
    assert!(
        progress.contains("installed pi-widgets -> 2.0.0"),
        "{progress}"
    );
    assert!(
        project
            .join(".pi/packages/pi-widgets/package.json")
            .is_file()
    );
    let settings = fs::read_to_string(project.join(".pi/settings.json")).unwrap();
    assert!(settings.contains("./packages/pi-widgets"), "{settings}");
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_package_installed_at_the_other_scope_blocks_the_install() {
    let tmp = fixture();
    let project = tmp.path().join("dev/app");
    fs::remove_dir_all(project.join(".pi/packages/pi-widgets")).unwrap();
    fs::write(project.join(".pi/settings.json"), "{}\n").unwrap();
    // The same package already lives at the global scope: Pi would load
    // both copies and crash at startup.
    write(
        &tmp.path()
            .join(".pi/agent/packages/pi-widgets/package.json"),
        "{\"name\": \"pi-widgets\", \"version\": \"1.0.0\"}\n",
    );

    let output = kendex(tmp.path(), &project, &["update-pi"]);
    assert!(output.status.success());
    assert!(!project.join(".pi/packages/pi-widgets").exists());
}

/// The other direction: the project the command runs in holds the package
/// and is registered nowhere, the way a fresh clone is, and the global
/// scope declares it. Pi loads that project's packages beside the global
/// ones all the same.
#[test]
#[allow(clippy::unwrap_used)]
fn a_package_in_the_unregistered_current_project_blocks_the_global_install() {
    let tmp = fixture();
    let project = tmp.path().join("dev/app");
    let env = kendex_core::env::Env::host_rooted(tmp.path());
    write(
        &env.global_manifest_file(),
        &format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[pi-extensions.pi-widgets]\nsource = \"cat\"\n",
            test_util::source_path(&project.join("catalog"))
        ),
    );

    let output = kendex(tmp.path(), &project, &["update-pi", "--scope", "global"]);
    assert!(output.status.success(), "{output:?}");
    assert!(!tmp.path().join(".pi/agent/packages/pi-widgets").exists());
}

/// One package under two spellings registers the same resources twice, so
/// the cross-scope guard blocks whichever spelling the manifest declares
/// against whichever the other root carries. Both directions: the guard
/// reaches the family through its current name, so neither declaration
/// need be the one the copy uses.
#[test]
#[allow(clippy::unwrap_used)]
fn a_package_at_the_other_scope_blocks_the_declared_name_under_either_spelling() {
    let rows = [
        (
            "declared scoped, installed unscoped",
            "@vanillagreen/pi-hooks",
            "pi-hooks",
        ),
        (
            "declared unscoped, installed scoped",
            "pi-hooks",
            "@vanillagreen/pi-hooks",
        ),
    ];
    for (case, declared, installed) in rows {
        let tmp = tempfile::tempdir().unwrap();
        let root = rooted(&tmp);
        let project = root.join("dev/app");
        write(
            &project.join("kendex.toml"),
            &format!(
                "schema = 6\n\n[sources.cat]\npath = \"catalog\"\n\n[pi-extensions.\"{declared}\"]\nsource = \"cat\"\n"
            ),
        );
        write(
            &project.join(format!("catalog/pi-extensions/{declared}/package.json")),
            &format!("{{\"name\": \"{declared}\", \"version\": \"1.0.0\"}}\n"),
        );
        fs::create_dir_all(project.join(".pi")).unwrap();
        // The other spelling of the same package sits at the global
        // scope, registering the same resources.
        let other_copy = root.join(format!(".pi/agent/packages/{installed}/package.json"));
        let other_bytes = format!("{{\"name\": \"{installed}\", \"version\": \"0.9.0\"}}\n");
        write(&other_copy, &other_bytes);

        let output = kendex(&root, &project, &["update-pi"]);
        assert!(output.status.success(), "{case}: {output:?}");
        assert_eq!(
            fs::read(&other_copy).unwrap(),
            other_bytes.as_bytes(),
            "{case}"
        );
        assert!(
            !project.join(".pi/packages").join(declared).exists(),
            "{case}: the declared name landed"
        );
    }
}

/// The probe a settle makes at its own root asks the family's OTHER
/// spellings, never the declared one. Blocked where the root holds the
/// copy an older kendex installed under an earlier name, which no record
/// accounts for: settling the scoped name would register the package
/// twice in one root. Settled where the only copy sits under the declared
/// name itself, which is every correctly installed catalog package, all
/// of which carry a rename entry — a probe that folded the whole family
/// would answer yes for each and settle none.
#[test]
#[allow(clippy::unwrap_used)]
fn a_settle_is_blocked_by_an_earlier_named_copy_and_runs_over_the_declared_one() {
    const SOURCE: &str = "{\"name\": \"@vanillagreen/pi-hooks\", \"version\": \"1.0.0\"}\n";
    let rows = [
        (
            "an earlier-named copy the record knows nothing about",
            ".pi/packages/pi-hooks/package.json",
            "{\"name\": \"pi-hooks\", \"version\": \"0.9.0\"}\n",
            false,
        ),
        (
            "the declared name's own copy, the source's bytes",
            ".pi/packages/@vanillagreen/pi-hooks/package.json",
            SOURCE,
            true,
        ),
    ];
    for (case, installed, bytes, settles) in rows {
        let tmp = tempfile::tempdir().unwrap();
        let root = rooted(&tmp);
        let project = root.join("dev/app");
        write(
            &project.join("kendex.toml"),
            "schema = 6\n\n[sources.cat]\npath = \"catalog\"\n\n[pi-extensions.\"@vanillagreen/pi-hooks\"]\nsource = \"cat\"\n",
        );
        write(
            &project.join("catalog/pi-extensions/pi-hooks/package.json"),
            SOURCE,
        );
        write(&project.join(installed), bytes);
        // No lock entry either way: the settle is what would write one.
        assert!(
            !project.join(".kendex-lock.json").exists(),
            "{case}: the fixture records nothing"
        );

        let output = kendex(&root, &project, &["refresh", "--scope", "project", "--yes"]);
        assert_eq!(output.status.success(), settles, "{case}: {output:?}");
        let key = kendex_core::lock::entry_key(
            kendex_core::model::ItemKind::PiExtension,
            "@vanillagreen/pi-hooks",
            kendex_core::model::HarnessId::Pi,
        );
        let recorded = kendex_core::lock::load(&project.join(".kendex-lock.json"))
            .unwrap()
            .entries
            .contains_key(&key);
        assert_eq!(recorded, settles, "{case}");
        if !settles {
            assert!(
                !project.join(".pi/packages/@vanillagreen").exists(),
                "{case}"
            );
        }
    }
}

/// Scripts use the exit status and the not-evaluated fields to identify
/// declarations that could not be compared, even when other updates land.
#[test]
fn unresolved_packages_fail_after_other_packages_update() {
    for source_path in ["missing-catalog", "catalog"] {
        let tmp = fixture();
        let project = tmp.path().join("dev/app");
        let manifest = project.join("kendex.toml");
        let mut text = fs::read_to_string(&manifest).unwrap();
        text.push_str(&format!(
            "\n[sources.unavailable]\npath = \"{source_path}\"\n\n[pi-extensions.pi-unavailable]\nsource = \"unavailable\"\n\n[pi-extensions.pi-unavailable-too]\nsource = \"unavailable\"\n"
        ));
        write(&manifest, &text);

        for check in [true, false, false] {
            let args: &[&str] = if check {
                &["update-pi", "--scope", "project", "--check"]
            } else {
                &["update-pi", "--scope", "project"]
            };
            let output = kendex(tmp.path(), &project, args);
            assert_eq!(output.status.code(), Some(1), "{source_path}");
            let notes = String::from_utf8_lossy(&output.stderr);
            for name in ["pi-unavailable", "pi-unavailable-too"] {
                let fields = format!(
                    "not-evaluated={name} scope={}",
                    project.canonicalize().unwrap().display()
                );
                assert_eq!(notes.matches(&fields).count(), 1, "{source_path}");
            }
            assert_eq!(
                fs::read_to_string(project.join(".pi/packages/pi-widgets/index.js")).unwrap(),
                if check {
                    "export const version = 1;\n"
                } else {
                    "export const version = 2;\n"
                }
            );
        }
    }
}

#[test]
fn unreadable_manifests_fail_after_the_other_scope_updates() {
    for (global, has_pi_root) in [(true, false), (true, true), (false, false), (false, true)] {
        let tmp = fixture();
        let project = tmp.path().join("dev/app");
        let env = kendex_core::env::Env::host_rooted(tmp.path());
        let (manifest, pi_root, installed, label) = if global {
            (
                env.global_manifest_file(),
                tmp.path().join(".pi/agent"),
                project.join(".pi/packages/pi-widgets/index.js"),
                "global".to_owned(),
            )
        } else {
            write(
                &env.global_manifest_file(),
                &format!(
                    "schema = 6\n\n[sources.cat]\n{}\n\n[pi-extensions.pi-widgets]\nsource = \"cat\"\n",
                    test_util::source_path(&project.join("catalog"))
                ),
            );
            fs::remove_dir_all(project.join(".pi")).unwrap();
            (
                project.join("kendex.toml"),
                project.join(".pi"),
                tmp.path().join(".pi/agent/packages/pi-widgets/index.js"),
                project.canonicalize().unwrap().display().to_string(),
            )
        };
        if has_pi_root {
            fs::create_dir_all(&pi_root).unwrap();
        }
        write(&manifest, "schema = [\n");

        let output = kendex(tmp.path(), &project, &["update-pi"]);

        assert_eq!(output.status.code(), Some(1));
        assert_eq!(
            fs::read_to_string(installed).unwrap(),
            "export const version = 2;\n"
        );
        let notes = String::from_utf8_lossy(&output.stderr);
        assert_eq!(
            notes
                .matches(&format!("not-evaluated=manifest scope={label}"))
                .count(),
            1
        );
        assert_eq!(fs::read_to_string(&manifest).unwrap(), "schema = [\n");
    }
}

/// The kendex catalog shelves scoped packages under short directories —
/// `pi-extensions/pi-hooks/` registering `@vanillagreen/pi-hooks`. The
/// declaration names the package, so the resolver falls back to the
/// package.json names when no directory matches the declared name.
#[test]
#[allow(clippy::unwrap_used)]
fn a_scoped_name_resolves_a_short_directory_by_package_name() {
    let tmp = tempfile::tempdir().unwrap();
    let project = tmp.path().join("dev/app");
    write(
        &project.join("kendex.toml"),
        "schema = 6\n\n[sources.cat]\npath = \"catalog\"\n\n[pi-extensions.\"@vanillagreen/pi-hooks\"]\nsource = \"cat\"\n",
    );
    write(
        &project.join("catalog/pi-extensions/pi-hooks/package.json"),
        "{\"name\": \"@vanillagreen/pi-hooks\", \"version\": \"1.1.0\"}\n",
    );
    write(
        &project.join(".pi/packages/@vanillagreen/pi-hooks/package.json"),
        "{\"name\": \"@vanillagreen/pi-hooks\", \"version\": \"1.0.0\"}\n",
    );

    let output = kendex(tmp.path(), &project, &["update-pi", "--check"]);
    assert!(output.status.success());
    let plan = String::from_utf8_lossy(&output.stdout);
    assert!(
        !plan.contains("nothing this place lists supplies it"),
        "{plan}"
    );
    assert!(!plan.contains("no longer ships"), "{plan}");
    assert!(plan.contains("stale"), "{plan}");

    let output = kendex(tmp.path(), &project, &["update-pi"]);
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let updated =
        fs::read_to_string(project.join(".pi/packages/@vanillagreen/pi-hooks/package.json"))
            .unwrap();
    assert!(updated.contains("1.1.0"), "{updated}");
}
