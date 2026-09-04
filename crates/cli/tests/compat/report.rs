use super::*;

#[test]
fn verify_cannot_pass_an_unreadable_record_without_a_usable_manifest() {
    let tmp = sandbox_with_catalog();
    let project = tmp.path().join("proj");
    fs::write(project.join(".kendex-lock.json"), "{\"version\":5}").unwrap();
    for manifest in [None, Some("invalid manifest")] {
        if let Some(manifest) = manifest {
            fs::write(project.join("kendex.toml"), manifest).unwrap();
        }
        let output = kendex_in(tmp.path(), &project, &["verify", "--scope", "project"], &[]);
        assert!(!output.status.success(), "{output:?}");
        assert!(
            stderr(&output).contains("install record unreadable"),
            "{output:?}"
        );
    }
}

#[test]
#[allow(
    clippy::too_many_lines,
    reason = "one table-shaped case: every ownership route judged against one sandbox, so splitting it would give each half a fixture of its own"
)]
fn report_dry_run_routes_by_ownership_and_rejects_scope_all() {
    let tmp = sandbox_with_catalog();
    let home = tmp.path();
    let proj = home.join("proj");
    // Locked assets from the canonical upstream route to it. The skill is
    // symlinked, as every installed skill is; delivery is not ownership.
    fs::write(
        proj.join(".kendex-lock.json"),
        lock_of(
            &proj,
            r#""agent:orch:claude":{"name":"orch","kind":"agent","harness":"claude","source":"kendex","sourceRepo":"vanillagreencom/kendex","method":"copy","installedAt":"2026-01-01T00:00:00Z","sourceHash":"x","enabled":true},"skill:size-ratchet:claude":{"name":"size-ratchet","kind":"skill","harness":"claude","source":"kendex","sourceRepo":"vanillagreencom/kendex","method":"symlink","installedAt":"2026-01-01T00:00:00Z","sourceHash":"x","enabled":true}"#,
        ),
    )
    .unwrap();

    let upstream = kendex_in(
        home,
        &proj,
        &[
            "report",
            "--agent",
            "orch",
            "--title",
            "T",
            "--body",
            "B",
            "--dry-run",
        ],
        &[],
    );
    assert!(upstream.status.success());
    let text = String::from_utf8_lossy(&upstream.stderr);
    assert!(text.contains("ownership: kendex"), "{text}");
    assert!(text.contains("--repo vanillagreencom/kendex"), "{text}");
    assert!(text.contains("--label skills"), "{text}");

    let skill = kendex_in(
        home,
        &proj,
        &[
            "report",
            "--skill",
            "size-ratchet",
            "--title",
            "T",
            "--body",
            "B",
            "--dry-run",
        ],
        &[],
    );
    assert!(skill.status.success());
    let text = String::from_utf8_lossy(&skill.stderr);
    assert!(text.contains("ownership: kendex"), "{text}");
    assert!(text.contains("--repo vanillagreencom/kendex"), "{text}");
    assert!(text.contains("--label skills"), "{text}");

    let local = kendex_in(
        home,
        &proj,
        &[
            "report",
            "--asset",
            "mystery",
            "--title",
            "T",
            "--body",
            "B",
            "--dry-run",
        ],
        &[],
    );
    let text = String::from_utf8_lossy(&local.stderr);
    assert!(text.contains("ownership: project-local"), "{text}");
    assert!(!text.contains("--label"), "{text}");

    // Naming a kind lets the lock resolve it: the label and the body marker
    // are the ones `--skill` would stamp.
    let asset = kendex_in(
        home,
        &proj,
        &[
            "report",
            "--asset",
            "size-ratchet",
            "--title",
            "T",
            "--body",
            "B",
            "--dry-run",
        ],
        &[],
    );
    assert!(asset.status.success());
    let text = String::from_utf8_lossy(&asset.stderr);
    assert!(text.contains("ownership: kendex"), "{text}");
    assert!(text.contains("--label skills"), "{text}");
    assert!(text.contains("kind=skill"), "{text}");

    // A named upstream the lock never recorded is not proof of ownership.
    let forked = kendex_in(
        home,
        &proj,
        &[
            "report",
            "--skill",
            "size-ratchet",
            "--upstream",
            "someone/else",
            "--title",
            "T",
            "--body",
            "B",
            "--dry-run",
        ],
        &[],
    );
    assert!(forked.status.success());
    let text = String::from_utf8_lossy(&forked.stderr);
    assert!(text.contains("ownership: project-local"), "{text}");
    assert!(!text.contains("someone/else"), "{text}");

    // A subscription spells the upstream however it likes, and the report
    // still files at the one place gh accepts: `owner/repo`, never the URL.
    let spelled = kendex_in(
        home,
        &proj,
        &[
            "report",
            "--skill",
            "size-ratchet",
            "--upstream",
            "git@github.com:vanillagreencom/kendex.git",
            "--title",
            "T",
            "--body",
            "B",
            "--dry-run",
        ],
        &[],
    );
    assert!(spelled.status.success());
    let text = String::from_utf8_lossy(&spelled.stderr);
    assert!(text.contains("ownership: kendex"), "{text}");
    assert!(text.contains("target: vanillagreencom/kendex"), "{text}");
    assert!(text.contains("--repo vanillagreencom/kendex"), "{text}");
    assert!(!text.contains("git@github.com"), "{text}");

    let rejected = kendex_in(
        home,
        &proj,
        &["report", "--title", "T", "--body", "B", "--scope", "all"],
        &[],
    );
    assert!(!rejected.status.success());
}

#[test]
fn report_routes_from_the_manifest_when_the_lock_is_unreadable() {
    let tmp = sandbox_with_catalog();
    let home = tmp.path();
    let proj = home.join("proj");
    fs::write(
        proj.join("kendex.toml"),
        "schema = 6\n\n[sources.kendex]\nrepo = \"vanillagreencom/kendex\"\n\n[skills.gh]\nsource = \"kendex\"\n\n[pi-extensions.\"@vanillagreen/pi-nested-agents-md\"]\nsource = \"kendex\"\n",
    )
    .unwrap();
    fs::write(proj.join(".kendex-lock.json"), r#"{"version":5}"#).unwrap();

    for selector in [["--skill", "gh"], ["--asset", "pi-nested-agents-md"]] {
        let output = kendex_in(
            home,
            &proj,
            &[
                "report",
                selector[0],
                selector[1],
                "--title",
                "T",
                "--body",
                "B",
                "--dry-run",
            ],
            &[],
        );
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        let text = String::from_utf8_lossy(&output.stderr);
        assert!(text.contains("install record unreadable"), "{text}");
        assert!(text.contains("ownership: kendex"), "{text}");
        assert!(text.contains("--repo vanillagreencom/kendex"), "{text}");
        assert!(text.contains("kendex routing warnings"), "{text}");
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn report_files_through_a_stubbed_gh() {
    let tmp = sandbox_with_catalog();
    let home = tmp.path();
    let proj = home.join("proj");

    let bin = home.join("bin");
    fs::create_dir_all(&bin).unwrap();
    let gh = bin.join("gh");
    fs::write(
        &gh,
        format!(
            "#!/bin/sh\nprintf '%s\\n' \"$@\" > {}/gh-args.txt\necho https://github.com/x/1\n",
            home.display()
        ),
    )
    .unwrap();
    fs::set_permissions(&gh, fs::Permissions::from_mode(0o755)).unwrap();
    let path = format!(
        "{}:{}",
        bin.display(),
        std::env::var("PATH").unwrap_or_default()
    );

    // Triage compares a report with the installed record, so the marker
    // carries what the lock recorded. An installation the lock never dated
    // says so and still files.
    for (recorded, stamped) in [
        (
            r#","sourceCommit":"abc1234def5678","renderedHash":"9f8e7d6c5b4a""#,
            "source=vanillagreencom/kendex@abc1234 rendered=9f8e7d6",
        ),
        ("", "source=unlocked rendered=unlocked"),
    ] {
        fs::write(
            proj.join(".kendex-lock.json"),
            lock_of(
                &proj,
                &format!(
                    r#""hook:guard:claude":{{"name":"guard","kind":"hook","harness":"claude","source":"kendex","sourceRepo":"vanillagreencom/kendex","method":"copy","installedAt":"2026-01-01T00:00:00Z","sourceHash":"x"{recorded},"enabled":true}}"#
                ),
            ),
        )
        .unwrap();

        let output = kendex_in(
            home,
            &proj,
            &[
                "report", "--hook", "guard", "--title", "Broken", "--body", "Details",
            ],
            &[("PATH", path.clone())],
        );
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        assert!(
            String::from_utf8_lossy(&output.stdout).contains("Issue filed: https://github.com/x/1")
        );
        let args = fs::read_to_string(home.join("gh-args.txt")).unwrap();
        assert!(args.contains("vanillagreencom/kendex"));
        assert!(args.contains("harness"));
        assert!(
            args.contains(&format!(
                "kendex-report:v1 asset=guard kind=hook ownership=kendex {stamped} -->"
            )),
            "{args}"
        );
    }
}
