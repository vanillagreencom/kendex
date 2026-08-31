//! The session-start `--check` gives up inside the budget the harness gives
//! the hook that runs it.
//!
//! Two files that have to agree and no code that reads both: the constant
//! carries a comment citing the hook's frontmatter, and the frontmatter
//! carries a number. Raise one or lower the other and every test still
//! passed while the bound stopped doing the only thing it was added for —
//! the harness killing the hook mid-check and losing the whole drift report
//! instead of the check folding a could-not-check line and the report
//! printing.

use kendex_core::drift::hook::HOOK_SCRIPT;
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
fn the_guard_check_timeout_fits_inside_the_hooks_budget() {
    let budget = declared_budget();
    assert!(
        CHECK_TIMEOUT.as_secs() < budget,
        "the session-start guard check may run for {}s inside a hook the harness gives {budget}s: \
         the harness kills the hook first and the whole drift report is lost, where the check \
         giving up first folds one could-not-check line and the rest of the report prints",
        CHECK_TIMEOUT.as_secs()
    );
}
