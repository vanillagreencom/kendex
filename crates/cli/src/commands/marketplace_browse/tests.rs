use kendex_core::model::{ItemKind, Scope};
use kendex_core::source::browse::{AvailablePackage, InstallState};

use super::*;
use crate::ui::testing::{plain, rich, tagged};
use crate::width::visible_width;

fn package(name: &str, summary: Option<&str>, state: InstallState) -> BrowseRow {
    (
        Scope::Global,
        "cat".to_owned(),
        AvailablePackage {
            kind: ItemKind::Skill,
            name: name.to_owned(),
            description: None,
            summary: summary.map(str::to_owned),
            tags: Vec::new(),
            bundles: Vec::new(),
            dependencies: Default::default(),
            state,
            collision: None,
            updated_at: None,
        },
    )
}

#[test]
fn marketplace_browse_snapshots() {
    let cells: Vec<Vec<String>> = [
        package("gh", Some("Work with GitHub"), InstallState::Available),
        package("tidy", None, InstallState::Installed),
    ]
    .into_iter()
    .map(package_cells)
    .collect();
    assert_eq!(
        listing(&plain(), &cells),
        [
            "global  cat::gh  (skill) [available]  — Work with GitHub",
            "global  cat::tidy  (skill) [installed]",
        ]
    );
    assert_eq!(
        tagged(&listing(&rich(100), &cells)),
        [
            "",
            "<1;36>packages</>  <90>2</>",
            "  <1;90>scope</>   <1;90>package</>    <1;90>kind</>                 <1;90>summary</>",
            "  <90>──────────────────────────────────────────────────────────</>",
            "  global  cat::gh    (skill) [available]  — Work with GitHub",
            "  global  cat::tidy  (skill) [installed]",
        ]
    );
    assert!(listing(&rich(80), &[]).is_empty());
}

/// A long summary wraps inside its column; the narrow cells stay whole.
#[test]
fn marketplace_browse_fits_the_width() {
    let summary = "word ".repeat(40);
    let cells = vec![package_cells(package(
        "gh",
        Some(&summary),
        InstallState::NotOffered,
    ))];
    let drawn = listing(&rich(80), &cells);
    assert!(
        drawn.iter().all(|line| visible_width(line) <= 80),
        "{drawn:#?}"
    );
    assert_eq!(drawn.join(" ").matches("word").count(), 40);
    assert_eq!(
        drawn
            .iter()
            .filter(|line| line.contains("[no longer offered]"))
            .count(),
        1,
        "{drawn:#?}"
    );
}
