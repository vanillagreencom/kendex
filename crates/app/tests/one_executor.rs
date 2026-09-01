//! One executor for a report, held by a fixture rather than by a comment.
//!
//! `repo_effects::execute` is where a report's plan gets written, because
//! that is where a leaving package's uninstaller runs while its scripts
//! are still on disk. A command that reaches past it into
//! `apply::execute(env, &report.plan)` compiles, previews the same, and
//! leaves the repository armed against files it just deleted — which is
//! how every desktop path came to do it. So the rule is read off the
//! source: nothing here executes a plan it took off a report.
//!
//! Read at statement scope rather than per line, because a line-local
//! match is a rule anybody reformats away by accident. `cargo fmt` wraps a
//! long call over four lines and does not join it back, and a plan bound
//! to a local puts the two halves in different statements — both shapes
//! are the defect, and a scan that misses them is guard code failing open.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

#[path = "../../test_util.rs"]
mod test_util;
use test_util::rooted;

fn src() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("src")
}

#[allow(clippy::unwrap_used)]
fn rust_files(dir: &Path, found: &mut Vec<PathBuf>) {
    for entry in std::fs::read_dir(dir).unwrap() {
        let path = entry.unwrap().path();
        if path.is_dir() {
            rust_files(&path, found);
        } else if path.extension().is_some_and(|ext| ext == "rs") {
            found.push(path);
        }
    }
}

/// The two files allowed to write a report's plan: the executor itself,
/// which is what it is for, and the editor's save tests, which exercise
/// core's apply rather than a command's report.
///
/// Named by path under `src`, never by file stem. A stem of `tests` also
/// exempted `app_update/tests.rs` and `launch_env/tests.rs`, and a stem of
/// `repo_effects` would exempt any future `src/**/repo_effects.rs` — an
/// exemption that widens on its own is the shape this scan exists to stop.
fn exempt(path: &Path, root: &Path) -> bool {
    let relative = path.strip_prefix(root).unwrap_or(path);
    matches!(
        kendex_core::paths::slashed(relative).as_str(),
        "repo_effects.rs" | "editor/save/tests.rs"
    )
}

/// The source with its line comments cut away, so prose describing this
/// rule cannot trip the scan and a call commented out cannot hide from it.
/// Quoting is tracked, so a `//` inside a string literal stays put.
fn without_line_comments(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for line in text.lines() {
        let bytes = line.as_bytes();
        let (mut quoted, mut cut, mut i) = (false, line.len(), 0);
        while i < bytes.len() {
            match bytes[i] {
                b'\\' if quoted => i += 1,
                b'"' => quoted = !quoted,
                b'/' if !quoted && bytes.get(i + 1) == Some(&b'/') => {
                    cut = i;
                    break;
                }
                _ => {}
            }
            i += 1;
        }
        out.push_str(&line[..cut]);
        out.push('\n');
    }
    out
}

fn is_ident(c: char) -> bool {
    c.is_alphanumeric() || c == '_'
}

/// Every `apply::execute(...)` in `text`: the line it opens on, and its
/// whole argument list with continuation lines joined — so a call rustfmt
/// spread over four lines reads exactly like one written on a single line.
fn calls(text: &str) -> Vec<(usize, String)> {
    const NEEDLE: &str = "apply::execute(";
    let mut found = Vec::new();
    let mut from = 0;
    while let Some(at) = text[from..].find(NEEDLE) {
        let open = from + at + NEEDLE.len();
        found.push((text[..open].lines().count(), balanced(&text[open..])));
        from = open;
    }
    found
}

/// The argument list up to the paren closing the one already open.
fn balanced(text: &str) -> String {
    let mut depth = 1usize;
    let mut out = String::new();
    for c in text.chars() {
        match c {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if depth == 0 {
                    break;
                }
            }
            _ => {}
        }
        out.push(if c == '\n' { ' ' } else { c });
    }
    out
}

/// Locals bound to a report's plan — `let plan = &report.plan;` — whose
/// call site then names only the local, so the word `plan` never appears
/// beside `apply::execute` at all.
fn plan_locals(text: &str) -> BTreeSet<String> {
    let mut names = BTreeSet::new();
    let mut from = 0;
    while let Some(at) = text[from..].find("let ") {
        let start = from + at;
        from = start + 4;
        // A statement's own `let`, not the tail of an identifier.
        if text[..start].chars().next_back().is_some_and(is_ident) {
            continue;
        }
        let statement = &text[from..];
        let statement = &statement[..statement.find(';').unwrap_or(statement.len())];
        let Some((bound, value)) = statement.split_once('=') else {
            continue;
        };
        if !value.contains(".plan") {
            continue;
        }
        // The name alone: a type annotation is not part of it, and a
        // pattern that is not one plain name binds no local to follow.
        let name = bound
            .split(':')
            .next()
            .unwrap_or(bound)
            .trim()
            .trim_start_matches("mut ")
            .trim();
        if !name.is_empty() && name.chars().all(is_ident) {
            names.insert(name.to_owned());
        }
    }
    names
}

/// Whether `args` passes `name` as a word of its own rather than as part
/// of some longer identifier.
fn passes(args: &str, name: &str) -> bool {
    args.match_indices(name).any(|(at, _)| {
        !args[..at].chars().next_back().is_some_and(is_ident)
            && !args[at + name.len()..].chars().next().is_some_and(is_ident)
    })
}

/// Every call under `root` that writes a plan it took off a report.
#[allow(clippy::unwrap_used)]
fn offenders(root: &Path) -> Vec<String> {
    let mut files = Vec::new();
    rust_files(root, &mut files);
    assert!(!files.is_empty(), "no sources found under {root:?}");
    files.sort();
    let mut found = Vec::new();
    for path in files.iter().filter(|path| !exempt(path, root)) {
        let text = without_line_comments(&std::fs::read_to_string(path).unwrap_or_default());
        let locals = plan_locals(&text);
        for (line, args) in calls(&text) {
            if args.contains(".plan") || locals.iter().any(|name| passes(&args, name)) {
                found.push(format!(
                    "{}:{line}: apply::execute({})",
                    path.display(),
                    args.trim()
                ));
            }
        }
    }
    found
}

#[test]
fn no_command_executes_a_report_s_plan_itself() {
    let found = offenders(&src());
    assert!(
        found.is_empty(),
        "these write a report's plan without running the leaving packages' \
         uninstallers — call repo_effects::execute instead:\n{}",
        found.join("\n")
    );
}

/// The scan run red once over each shape the defect has: written on one
/// line, wrapped by rustfmt, and split across two statements through a
/// local. It spares the bare plan a command may execute on its own, and it
/// spares only the two files named by their path — a stem-shaped exemption
/// let `app_update/tests.rs` through, which is why that one is planted.
#[test]
#[allow(clippy::unwrap_used)]
fn the_scan_names_every_shape_of_a_report_s_plan_and_spares_a_bare_one() {
    let tmp = tempfile::tempdir().unwrap();
    let root = rooted(&tmp);
    let write = |relative: &str, body: &str| {
        let path = root.join(relative);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, body).unwrap();
    };

    // One line, the shape the original defect had.
    write(
        "marketplaces/install.rs",
        "fn go(env: &Env, report: &EngineReport) {\n\
         \x20   apply::execute(env, &report.plan).unwrap();\n}\n",
    );
    // Wrapped, the shape `cargo fmt` produces and does not undo.
    write(
        "sources.rs",
        "fn go(env: &Env, report: &EngineReport) {\n\
         \x20   apply::execute(\n\
         \x20       env,\n\
         \x20       &report.plan,\n\
         \x20   )\n\
         \x20   .unwrap();\n}\n",
    );
    // Two statements, with the plan behind a local.
    write(
        "audit.rs",
        "fn go(env: &Env, report: &EngineReport) {\n\
         \x20   let plan = &report.plan;\n\
         \x20   apply::execute(env, plan).unwrap();\n}\n",
    );
    // A test file that is not the exempt one: a stem-shaped exemption
    // spared this, and it is a real path under src.
    write(
        "app_update/tests.rs",
        "fn go(env: &Env, report: &EngineReport) {\n\
         \x20   apply::execute(env, &report.plan).unwrap();\n}\n",
    );
    // Spared: a bare plan with no report behind it.
    write(
        "packages.rs",
        "fn go(env: &Env, plan: &Plan) {\n\
         \x20   apply::execute(env, plan).unwrap();\n}\n",
    );
    // Spared by path: the executor, and the editor's save tests.
    write(
        "repo_effects.rs",
        "fn go(env: &Env, report: &EngineReport) {\n\
         \x20   apply::execute(env, &report.plan).unwrap();\n}\n",
    );
    write(
        "editor/save/tests.rs",
        "fn go(env: &Env, report: &EngineReport) {\n\
         \x20   apply::execute(env, &report.plan).unwrap();\n}\n",
    );

    let found = offenders(&root);
    let named = |file: &str, line: usize| {
        let want = format!("{file}:{line}:");
        assert!(
            found.iter().any(|hit| hit.contains(&want)),
            "{want} went uncaught:\n{}",
            found.join("\n")
        );
    };
    named("marketplaces/install.rs", 2);
    named("sources.rs", 2);
    named("audit.rs", 3);
    named("app_update/tests.rs", 2);
    assert_eq!(found.len(), 4, "{found:#?}");
}

/// A `//` inside a string literal is not a comment, and a call the scan
/// would catch is not hidden by commenting it out.
#[test]
#[allow(clippy::unwrap_used)]
fn comments_are_cut_and_string_literals_are_not() {
    let tmp = tempfile::tempdir().unwrap();
    let root = rooted(&tmp);
    std::fs::write(
        root.join("commented.rs"),
        "fn go() {\n\
         \x20   // apply::execute(env, &report.plan);\n\
         \x20   let url = \"https://example.invalid/x\";\n}\n",
    )
    .unwrap();

    assert!(offenders(&root).is_empty());
    assert!(
        without_line_comments("let url = \"http://a\"; // gone\n").contains("http://a"),
        "the scheme's slashes were read as a comment"
    );
}
