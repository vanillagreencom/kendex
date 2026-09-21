//! The session-start check gives up inside the budget the harness gives
//! the hook that runs it: the commit-hook `--check` and the plan over
//! declarations sitting on unrecorded files, which one hook run spends
//! one after the other. The hook's check covers the project and the
//! global scope in one run, and the plan's budget is one deadline over
//! both (`unmanaged_check::budget`), so the sum below is the run's
//! ceiling whatever the scope count.
//!
//! Three values that have to agree and no code that reads all three: each
//! constant carries a comment citing the hook's frontmatter, and the
//! frontmatter carries a number. Their relationship keeps the harness
//! from killing the hook mid-check and losing the whole drift report
//! before the check can fold a could-not-check line and print the report.

use kendex_core::drift::hook::{DEEP_PASS_BUDGET, HOOK_SCRIPT};
use kendex_core::guard::CHECK_TIMEOUT;

/// The hook's own declared budget, in seconds, read out of the frontmatter
/// the harness reads.
#[allow(clippy::expect_used)]
fn declared_budget() -> u64 {
    HOOK_SCRIPT
        .lines()
        .find_map(|line| line.trim_start_matches("# ").strip_prefix("timeout: "))
        .expect("the drift hook declares a timeout in its frontmatter")
        .trim()
        .parse()
        .expect("the declared timeout is a whole number of seconds")
}

#[test]
fn the_checks_two_timeouts_fit_inside_the_hooks_budget_together() {
    let budget = declared_budget();
    let spent = CHECK_TIMEOUT.as_secs() + DEEP_PASS_BUDGET.as_secs();
    assert!(
        spent < budget,
        "the session-start guard check may run for {}s and the plans over unrecorded copies, \
         project and global scope together, for {}s, one after the other, inside a hook the \
         harness gives {budget}s: the harness kills the hook first and the whole drift report \
         is lost, where the check giving up first folds one could-not-check line and the rest \
         of the report prints",
        CHECK_TIMEOUT.as_secs(),
        DEEP_PASS_BUDGET.as_secs()
    );
}
