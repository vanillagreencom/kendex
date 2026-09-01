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
//!
//! What it rests on, said plainly so nobody mistakes it for total: the
//! call is found by the literal text `apply::execute(`. An unqualified
//! `use kendex_core::apply::execute;` followed by a bare `execute(env,
//! &report.plan)`, or a function pointer bound to it, passes unseen.
//! Neither exists anywhere in `crates/app/src` or `crates/cli/src`, and
//! module-path style is the house convention, so evading this takes a
//! deliberate import rather than an accident — which is why the rule is
//! written against the shape people actually type and no machinery
//! chases the other one.

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

/// The source with everything that is not code blanked out: line comments,
/// block comments, and the insides of string and character literals.
///
/// Blanked rather than deleted, so every byte offset and line number still
/// points where it did. Comments were the first half of this — prose
/// describing the rule must not trip a scan of the rule, in either
/// direction — and literals are the other half, for two reasons. A message
/// quoting `apply::execute(env, &report.plan)` is exactly what a
/// diagnostic about this rule looks like, and `write_nothing_leaving`
/// already names its own rule that way. And a paren or a semicolon inside
/// a string is not one this parser should be counting.
fn code_only(text: &str) -> String {
    #[derive(PartialEq)]
    enum In {
        Code,
        Line,
        Block(usize),
        Str,
        Raw(usize),
        Chr,
    }
    let mut state = In::Code;
    let mut out = String::with_capacity(text.len());
    let bytes = text.as_bytes();
    let mut i = 0;
    // Kept verbatim only in `Code`; everywhere else a byte becomes a space
    // and a newline stays a newline.
    let keep = |out: &mut String, byte: u8, verbatim: bool| {
        match (byte, verbatim) {
            (b'\n', _) => out.push('\n'),
            (_, true) => out.push(byte as char),
            (_, false) => out.push(' '),
        };
    };
    while i < bytes.len() {
        let byte = bytes[i];
        let next = bytes.get(i + 1).copied();
        match state {
            In::Code => {
                // A raw string: `r`, any number of `#`, then the quote.
                let raw = byte == b'r' && {
                    let mut j = i + 1;
                    while bytes.get(j) == Some(&b'#') {
                        j += 1;
                    }
                    bytes.get(j) == Some(&b'"')
                        && !text[..i].chars().next_back().is_some_and(is_ident)
                };
                if raw {
                    let mut hashes = 0;
                    while bytes.get(i + 1 + hashes) == Some(&b'#') {
                        hashes += 1;
                    }
                    for _ in 0..=hashes + 1 {
                        keep(&mut out, b' ', false);
                    }
                    i += hashes + 2;
                    state = In::Raw(hashes);
                    continue;
                }
                match (byte, next) {
                    (b'/', Some(b'/')) => state = In::Line,
                    (b'/', Some(b'*')) => state = In::Block(1),
                    (b'"', _) => state = In::Str,
                    // A character literal, not a lifetime: `'a'` and
                    // `'\n'` close, `'a` in `&'a str` never does.
                    (b'\'', Some(b'\\')) => state = In::Chr,
                    (b'\'', _) if bytes.get(i + 2) == Some(&b'\'') => state = In::Chr,
                    _ => {}
                }
                keep(&mut out, byte, state == In::Code);
                i += 1;
            }
            In::Line => {
                keep(&mut out, byte, false);
                if byte == b'\n' {
                    state = In::Code;
                }
                i += 1;
            }
            In::Block(depth) => {
                if (byte, next) == (b'/', Some(b'*')) {
                    state = In::Block(depth + 1);
                    keep(&mut out, byte, false);
                    keep(&mut out, b' ', false);
                    i += 2;
                    continue;
                }
                if (byte, next) == (b'*', Some(b'/')) {
                    state = match depth {
                        1 => In::Code,
                        _ => In::Block(depth - 1),
                    };
                    keep(&mut out, byte, false);
                    keep(&mut out, b' ', false);
                    i += 2;
                    continue;
                }
                keep(&mut out, byte, false);
                i += 1;
            }
            In::Str | In::Chr => {
                let closing = match state {
                    In::Str => b'"',
                    _ => b'\'',
                };
                if byte == b'\\' {
                    keep(&mut out, byte, false);
                    if let Some(escaped) = next {
                        keep(&mut out, escaped, false);
                    }
                    i += 2;
                    continue;
                }
                if byte == closing {
                    state = In::Code;
                }
                keep(&mut out, byte, false);
                i += 1;
            }
            In::Raw(hashes) => {
                let closes =
                    byte == b'"' && (0..hashes).all(|n| bytes.get(i + 1 + n) == Some(&b'#'));
                keep(&mut out, byte, false);
                i += 1;
                if closes {
                    for _ in 0..hashes {
                        keep(&mut out, b' ', false);
                    }
                    i += hashes;
                    state = In::Code;
                }
            }
        }
    }
    out
}

fn is_ident(c: char) -> bool {
    c.is_alphanumeric() || c == '_'
}

/// Whether `text` names a report's `plan` field rather than some longer
/// name that merely begins with it — `planned_at`, `plans`, `plan_b`.
fn names_a_plan(text: &str) -> bool {
    text.match_indices(".plan").any(|(at, _)| {
        !text[at + ".plan".len()..]
            .chars()
            .next()
            .is_some_and(is_ident)
    })
}

/// The file split at each `fn`, so a local bound in one function cannot
/// explain a call in another. Everything before the first `fn` is a span
/// of its own, so nothing at module scope is skipped.
fn functions(text: &str) -> Vec<(usize, &str)> {
    let mut bounds = vec![0usize];
    let mut from = 0;
    while let Some(at) = text[from..].find("fn ") {
        let at = from + at;
        from = at + 3;
        if text[..at].chars().next_back().is_some_and(is_ident) {
            continue;
        }
        bounds.push(at);
    }
    bounds.push(text.len());
    bounds.dedup();
    bounds
        .windows(2)
        .map(|pair| (pair[0], &text[pair[0]..pair[1]]))
        .collect()
}

/// Every `apply::execute(...)` in `text`: where it opens, and its whole
/// argument list with continuation lines joined — so a call rustfmt spread
/// over four lines reads exactly like one written on a single line.
fn calls(text: &str) -> Vec<(usize, String)> {
    const NEEDLE: &str = "apply::execute(";
    let mut found = Vec::new();
    let mut from = 0;
    while let Some(at) = text[from..].find(NEEDLE) {
        let open = from + at + NEEDLE.len();
        found.push((from + at, balanced(&text[open..])));
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

/// Where the statement beginning at `text` ends: the first `;` outside any
/// bracket.
///
/// The first `;` of any depth is a different thing, and taking it read
/// `let plan = match kind { A => &a.plan, B => { warn(); &b.plan } };` as
/// ending inside the block — so the local went unrecorded and the call
/// that passed it went unnamed.
fn statement_end(text: &str) -> usize {
    let mut depth = 0i32;
    for (at, c) in text.char_indices() {
        match c {
            '{' | '[' | '(' => depth += 1,
            '}' | ']' | ')' => depth -= 1,
            ';' if depth <= 0 => return at,
            _ => {}
        }
    }
    text.len()
}

/// Locals bound to a report's plan — `let plan = &report.plan;` — whose
/// call site then names only the local, so the word `plan` never appears
/// beside `apply::execute` at all.
///
/// Read per function, never per file. File-scoped, a `let plan =
/// row.planned_at();` in one function condemned a legitimately bare
/// `apply::execute(env, plan)` in another, which `commands.rs` is one
/// rename away from today.
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
        let statement = &statement[..statement_end(statement)];
        let Some((bound, value)) = statement.split_once('=') else {
            continue;
        };
        if !names_a_plan(value) {
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

/// Every problem under `root`: a call that writes a plan it took off a
/// report, and any file the scan could not read.
///
/// A file it cannot read is a problem, never a clean one. Reading it as an
/// empty string made an unreadable or non-UTF-8 file scan as blank source,
/// which retired this rule for that file and said nothing — and this scan
/// is the only guard eight of the ten rerouted paths have.
///
/// Every path is rendered through `paths::slashed`, the same call `exempt`
/// reads through. Once one side of a comparison is a value from there the
/// other has to be too, or the two agree only where the platform's own
/// separator already matches — which is a class of failure only Windows CI
/// sees, one run per push.
#[allow(clippy::unwrap_used)]
fn offenders(root: &Path) -> Vec<String> {
    let mut files = Vec::new();
    rust_files(root, &mut files);
    assert!(!files.is_empty(), "no sources found under {root:?}");
    files.sort();
    let mut found = Vec::new();
    for path in files.iter().filter(|path| !exempt(path, root)) {
        let shown = kendex_core::paths::slashed(path);
        let text = match std::fs::read_to_string(path) {
            Ok(source) => code_only(&source),
            Err(error) => {
                found.push(format!(
                    "{shown}: unread, so the rule went unchecked here: {error}"
                ));
                continue;
            }
        };
        for (start, body) in functions(&text) {
            let locals = plan_locals(body);
            for (at, args) in calls(body) {
                if !names_a_plan(&args) && !locals.iter().any(|name| passes(&args, name)) {
                    continue;
                }
                let line = text[..start + at].lines().count();
                found.push(format!("{shown}:{line}: apply::execute({})", args.trim()));
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
        "the one-executor rule is not held. Each line is either a call that \
         writes a report's plan without running the leaving packages' \
         uninstallers — call repo_effects::execute instead — or a file the \
         scan could not read, which is not the same as a file with nothing \
         in it:\n{}",
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
    // Spelled through the same call the hits are, and anchored at the
    // path rather than matched anywhere in the line. A literal built with
    // `/` never matches a hit Windows rendered with `\`, and the
    // single-segment cases hid it by having no separator to disagree
    // about — so both sides go through `slashed` over the same root.
    let named = |file: &str, line: usize| {
        let want = format!("{}:{line}:", kendex_core::paths::slashed(&root.join(file)));
        assert!(
            found.iter().any(|hit| hit.starts_with(&want)),
            "{want} went uncaught:\n{}",
            found.join("\n")
        );
    };
    named("marketplaces/install.rs", 2);
    named("sources.rs", 2);
    named("audit.rs", 3);
    named("app_update/tests.rs", 2);
    assert_eq!(found.len(), 4, "{found:#?}");
    // The hits are spelled the way `slashed` spells them, not the way the
    // platform does. This assertion is vacuous on Unix, where the two
    // agree, and is the whole guard on Windows, where `display()` writes
    // `\` and an expectation spelled with `/` then matches nothing. It is
    // here because that class costs one CI run per push to find.
    assert!(
        found.iter().all(|hit| !hit.contains('\\')),
        "a hit was rendered with the platform separator rather than slashed: {found:#?}"
    );
}

/// Nothing that is not code condemns a file, in any of the three ways it
/// can look like code.
///
/// Guard code that cries wolf is guard code somebody turns off. The
/// rule-quoting string is not hypothetical: `write_nothing_leaving` names
/// its own rule in its own refusal message, and a diagnostic about THIS
/// rule would be spelled exactly like the one planted here.
#[test]
#[allow(clippy::unwrap_used)]
fn nothing_outside_code_is_read_as_code() {
    let tmp = tempfile::tempdir().unwrap();
    let root = rooted(&tmp);
    std::fs::write(
        root.join("innocent.rs"),
        "fn go() {\n\
         \x20   // apply::execute(env, &report.plan);\n\
         \x20   /* and again:\n\
         \x20      apply::execute(env, &report.plan);\n\
         \x20   */\n\
         \x20   let msg = \"call apply::execute(env, &report.plan) never\";\n\
         \x20   let url = \"https://example.invalid/x\";\n\
         \x20   let raw = r#\"apply::execute(env, &report.plan)\"#;\n}\n",
    )
    .unwrap();

    assert!(offenders(&root).is_empty(), "{:?}", offenders(&root));
    // And the blanking leaves code alone: a scheme's slashes are not a
    // comment, and the file still parses as the statements it holds.
    let kept = code_only("let url = \"http://a\"; // gone\nlet n = 1;\n");
    assert!(kept.contains("let url ="), "{kept:?}");
    assert!(kept.contains("let n = 1;"), "{kept:?}");
    assert!(!kept.contains("gone"), "{kept:?}");
    assert!(!kept.contains("http://a"), "{kept:?}");
}

/// A local bound to a plan in one function does not condemn a bare call in
/// another, and a name that merely starts with `plan` binds nothing.
///
/// Both have live reach: `commands.rs` holds a `.plan`-derived local and a
/// legitimately bare `apply::execute` in the same file today, kept apart
/// only by their names.
#[test]
#[allow(clippy::unwrap_used)]
fn a_plan_local_condemns_only_its_own_function() {
    let tmp = tempfile::tempdir().unwrap();
    let root = rooted(&tmp);
    std::fs::write(
        root.join("commands.rs"),
        // The same NAME in both functions: one bound off a report, one a
        // plain parameter. File-scoped, the first condemns the second.
        "fn peek(report: &EngineReport) -> Plan {\n\
         \x20   let plan = report.plan.clone();\n\
         \x20   plan\n}\n\
         fn go(env: &Env, plan: &Plan) {\n\
         \x20   apply::execute(env, plan).unwrap();\n}\n\
         fn later(env: &Env, row: &Row) {\n\
         \x20   let plan = row.planned_at();\n\
         \x20   apply::execute(env, plan).unwrap();\n}\n\
         fn beside(env: &Env, row: &Row) {\n\
         \x20   apply::execute(env, &row.planned).unwrap();\n}\n",
    )
    .unwrap();

    assert!(offenders(&root).is_empty(), "{:?}", offenders(&root));
}

/// The two shapes that used to slip past: a semicolon inside the value a
/// local is bound to, and a paren inside a string in the argument list.
#[test]
#[allow(clippy::unwrap_used)]
fn a_statement_is_read_to_its_own_end() {
    let tmp = tempfile::tempdir().unwrap();
    let root = rooted(&tmp);
    std::fs::write(
        root.join("audit.rs"),
        "fn go(env: &Env, report: &EngineReport, kind: Kind) {\n\
         \x20   let plan = match kind { A => { warn(); &a.plan }, B => &b.plan };\n\
         \x20   apply::execute(env, plan).unwrap();\n}\n",
    )
    .unwrap();
    std::fs::write(
        root.join("sources.rs"),
        "fn go(env: &Env, report: &EngineReport) {\n\
         \x20   apply::execute(env, closer(\")\"), &report.plan).unwrap();\n}\n",
    )
    .unwrap();

    let found = offenders(&root);
    // Single-segment names, and spelled through `slashed` anyway: this is
    // where the next multi-segment expectation gets added.
    for (file, line) in [("audit.rs", 3), ("sources.rs", 2)] {
        let want = format!("{}:{line}:", kendex_core::paths::slashed(&root.join(file)));
        assert!(
            found.iter().any(|hit| hit.starts_with(&want)),
            "{want} went uncaught:\n{}",
            found.join("\n")
        );
    }
    assert_eq!(found.len(), 2, "{found:#?}");
}

/// A file the scan cannot read is a problem, not a clean file.
///
/// Reading it as an empty string made it scan as blank source, so the rule
/// went unenforced for that file and nothing said so. This scan is the
/// only guard eight of the ten rerouted paths have, so a silent read
/// failure retires the rule for whichever file failed — which is guard
/// code failing in the one direction that matters.
#[test]
#[allow(clippy::unwrap_used)]
fn a_file_the_scan_cannot_read_is_named_rather_than_passed() {
    let tmp = tempfile::tempdir().unwrap();
    let root = rooted(&tmp);
    // Not UTF-8, so `read_to_string` refuses it whatever its permissions,
    // which is a state every platform reaches the same way.
    std::fs::write(root.join("packages.rs"), [0x66, 0x6e, 0x20, 0xff, 0xfe]).unwrap();

    let found = offenders(&root);

    let want = kendex_core::paths::slashed(&root.join("packages.rs"));
    assert_eq!(found.len(), 1, "{found:#?}");
    assert!(
        found[0].starts_with(&format!("{want}: unread")),
        "{found:#?}"
    );
    assert!(found[0].contains("went unchecked"), "{found:#?}");
}
