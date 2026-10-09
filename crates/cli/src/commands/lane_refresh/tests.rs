//! Times the actual pre-bootstrap guard, excluding fixture setup and dispatch.
//! The integration writer table keeps the real command and destination effects.

use std::fs;
use std::time::Instant;

use clap::Parser;

use super::check_project_writes_in;
use crate::test_util::lane::Fixture;
use kendex_core::env::Env;

#[test]
#[allow(clippy::expect_used, reason = "fixture setup must succeed")]
fn parsed_guard_reports_each_command_time_over_caller_layouts() {
    let mut fixture = Fixture::new("KEN-3464");
    let caller = fixture.main.join(".claude/worktrees/caller");
    fs::create_dir_all(caller.parent().expect("caller parent")).expect("worktree parent");
    fixture.git(
        &fixture.main,
        &[
            "worktree",
            "move",
            fixture.linked.to_str().expect("linked path"),
            caller.to_str().expect("caller path"),
        ],
    );
    fixture.linked = caller;
    fs::write(fixture.main.join("kendex.toml"), "schema = 6\n").expect("project manifest");
    for (name, bare) in [("vendor", false), ("bare", true)] {
        let mut args = vec!["clone", "-q"];
        if bare {
            args.push("--bare");
        }
        args.extend([fixture.main.to_str().expect("main path"), name]);
        fixture.git(&fixture.linked, &args);
    }
    let plain = fixture.root.join("non-repository");
    fs::create_dir(&plain).expect("plain project");
    fs::write(plain.join("kendex.toml"), "schema = 6\n").expect("plain manifest");
    let layouts = [
        ("non-repository", plain, false),
        ("main", fixture.main.clone(), false),
        ("linked", fixture.linked.clone(), true),
        ("vendor", fixture.linked.join("vendor"), true),
        ("bare", fixture.linked.join("bare"), true),
    ];
    let mut samples = Vec::new();
    for (layout, cwd, refused) in layouts {
        let env = Env::host_rooted(&fixture.root).with_cwd(&cwd);
        for verb in ["refresh", "apply", "updates"] {
            let mut args = vec!["kendex", verb, "--scope", "project"];
            if verb == "updates" {
                args.push("--apply");
            }
            let cli = crate::Cli::try_parse_from(args).expect("parsed writer");
            let started = Instant::now();
            let result = check_project_writes_in(&cli, &env).expect("guard resolves");
            let elapsed = started.elapsed();
            assert_eq!(result.is_some(), refused, "{verb} {layout}");
            if let Some(key) = result {
                assert!(key.starts_with("worktree-project-write: target="));
            }
            // The output owner writes directly when libtest captures passing tests.
            crate::ui::stderr(&[format!(
                "lane-refresh-guard command={verb} layout={layout} seconds={:.6}",
                elapsed.as_secs_f64()
            )]);
            samples.push(elapsed);
        }
    }
    // The same writer can target its own project; a launch marker still
    // refuses that write until the explicit override is present.
    fs::write(fixture.linked.join("kendex.toml"), "schema = 6\n").expect("own manifest");
    let env = Env::host_rooted(&fixture.root).with_cwd(&fixture.linked);
    let cli = crate::Cli::try_parse_from(["kendex", "refresh", "--scope", "project"])
        .expect("own writer");
    assert!(
        check_project_writes_in(&cli, &env)
            .expect("own check")
            .is_none()
    );
    fixture.mark();
    let marked = check_project_writes_in(&cli, &env)
        .expect("marked check")
        .expect("marked refusal");
    assert!(marked.starts_with("lane-refresh: item=KEN-3464;"));
    let overridden =
        crate::Cli::try_parse_from(["kendex", "refresh", "--scope", "project", "--lane-refresh"])
            .expect("override writer");
    assert!(
        check_project_writes_in(&overridden, &env)
            .expect("override check")
            .is_none()
    );
    samples.sort_unstable();
    let median = samples[samples.len() / 2];
    let max = samples.last().expect("guard samples");
    crate::ui::stderr(&[format!(
        "lane-refresh-guard samples={} median_seconds={:.6} max_seconds={:.6}",
        samples.len(),
        median.as_secs_f64(),
        max.as_secs_f64()
    )]);
}
