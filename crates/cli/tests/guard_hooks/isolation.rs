//! A hosted lane can allocate temporary directories inside a checkout.
//! Re-execution gives each fixture that layout without changing the harness.

use crate::test_util::{lane::snapshot, rooted};

use super::{armed_repo, said};

#[test]
#[allow(
    clippy::unwrap_used,
    reason = "fixture setup and child launch must succeed"
)]
fn temporary_directories_inside_a_checkout_leave_ancestor_hooks_unchanged() {
    for test in [
        "install_ux::guarding::removing_from_a_plain_directory_runs_no_uninstaller",
        "guard_hooks::arming::a_declared_project_outside_a_repository_has_no_hook_verdict",
        "install_ux::coexistence::version_10_recovery_works_outside_git",
        "guard_hooks::arming::disarming_leaves_a_pre_existing_hook_behind",
    ] {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        // A real armed fixture intercepts discovery even in the must-fail
        // control. No child can select the developer's shared hooks.
        let ancestor = armed_repo(&home);
        let allocation = ancestor.join("temporary allocations");
        std::fs::create_dir(&allocation).unwrap();
        let hooks = ancestor.join(".git/hooks");
        let before = snapshot(&hooks);
        let output = crate::test_util::reexecute_test(
            "integration",
            test,
            &[
                ("TMPDIR", allocation.to_str().unwrap()),
                ("PATH", &std::env::var("PATH").unwrap()),
            ],
        )
        .unwrap();
        assert_eq!(
            snapshot(&hooks),
            before,
            "{test} changed ancestor hooks: {}",
            said(&output)
        );
        assert!(output.status.success(), "{test}: {}", said(&output));
        // libtest succeeds when an exact filter matches nothing. Its named
        // completion record proves the requested child ran and passed.
        let passed = format!("test {test} ... ok");
        assert!(
            String::from_utf8_lossy(&output.stdout)
                .lines()
                .any(|line| line == passed),
            "{test} did not run and pass: {}",
            said(&output)
        );
    }
}
