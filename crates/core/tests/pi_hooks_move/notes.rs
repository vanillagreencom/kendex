//! What the lines say, and when they say it.
//!
//! Notes are made while the plan is made, and `refresh` prints them before
//! it applies anything — so a preview, a confirmation the person declines,
//! and a plan that fails partway all show them. A line that says a hook
//! stopped running, while it is still running, is one the person acts on.

use std::fs;

use kendex_core::engine::{PlanOptions, audit, plan_apply};

use super::{regressed, undeclare};

/// The retirement line: read before the apply, it is describing something
/// that has not happened, beside a file that is still on disk.
#[test]
#[allow(clippy::unwrap_used)]
fn the_line_about_a_retirement_is_read_before_the_retirement() {
    let w = regressed();
    undeclare(&w);

    let report = plan_apply(
        &w.env,
        &w.scope(),
        &PlanOptions {
            remove_orphans: true,
            sweep_unneeded: true,
            ..PlanOptions::default()
        },
    )
    .unwrap();

    let said = report.notes.join("\n");
    assert!(
        said.contains("nothing asks for the pi hook guard any more"),
        "the line is there to read: {said}"
    );
    assert!(
        said.contains("once this is applied"),
        "and says its own tense: {said}"
    );
    assert!(
        w.dot().join("hooks/guard.sh").is_file(),
        "because at this point the hook is still exactly where it was"
    );

    kendex_core::apply::execute(&w.env, &report.plan, None).unwrap();
    assert!(!w.dot().join("hooks").exists(), "and then it is not");
}

/// The same of the directory line, which is the other one that describes
/// kendex doing something rather than declining to.
#[test]
#[allow(clippy::unwrap_used)]
fn the_line_about_an_empty_directory_is_read_before_it_goes() {
    let w = regressed();
    super::apply(&w);
    super::forget_the_move(&w.project.join(".kendex-lock.json"));
    fs::create_dir_all(w.dot().join("hooks")).unwrap();

    let report = audit(&w.env, &w.scope()).unwrap();
    let said = report.notes.join("\n");
    assert!(
        said.contains("this plan removes it"),
        "the line says whose doing it is and when: {said}"
    );
    assert!(
        w.dot().join("hooks").is_dir(),
        "and the directory is still there while it is being read"
    );
}
