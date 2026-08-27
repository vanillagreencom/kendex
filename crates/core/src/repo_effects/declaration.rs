//! Reading a `repo-effects` declaration out of a package's frontmatter.
//!
//! Its own file because it is one edge with one rule: text a catalog wrote,
//! turned into values kendex will act on, and refused whole where any of it
//! cannot be read. Nothing here touches disk or runs anything — that is next
//! door, and it takes only what this hands back.

use serde::{Deserialize, Serialize};
use specta::Type;

use crate::frontmatter::{Map, Value};

use super::KEY;

/// A package's declared effects on the repository it installs into.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct RepoEffects {
    /// One line: what installing this changes about the repository.
    pub summary: String,
    /// Repo-relative paths the package writes outside the managed trees.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub writes: Vec<String>,
    /// The script, relative to the package directory, that applies the
    /// effect. Absent means kendex has nothing to run and the disclosure
    /// ends with what the reader should run themselves.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub installer: Option<String>,
    /// The script that undoes the effect.
    ///
    /// Declared, not yet run: nothing in kendex executes it, and `remove`
    /// takes the package's files away with the effect still applied. The
    /// disclosure names it so a person can run it themselves, which is the
    /// whole of what it does today. KEN-674 carries wiring it into removal.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub uninstaller: Option<String>,
    /// How to undo the effect by hand, for the disclosure's last line.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub removal: Option<String>,
    /// Lines the package wants read before anyone says yes — what its
    /// effect actually does, in its own words. The package writes these
    /// because only it knows them; kendex supplies the parts it owns, the
    /// paths and the authorization and the removal command.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub notes: Vec<String>,
    /// Packages whose presence changes what this one does. Whether each is
    /// installed here is a fact about this repository rather than about the
    /// package, so the declaration names them and kendex answers.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub companions: Vec<String>,
}

/// The declaration in one package's `SKILL.md`, or `None` where there is
/// none — which is the ordinary case and never an error.
///
/// A malformed declaration is also `None`: a package whose effects cannot
/// be read is treated as declaring none, and its installer is therefore
/// never run. Failing that way round is the safe one — the alternative is
/// running a script whose disclosure kendex could not show.
pub fn declared(skill_md: &str) -> Option<RepoEffects> {
    let (yaml, _) = crate::frontmatter::split(skill_md).ok()?;
    let parsed = crate::frontmatter::parse_tolerant(yaml).ok()?;
    let Some(Value::Map(map)) = parsed.map.get(KEY) else {
        return None;
    };
    let summary = scalar(map, "summary")?;
    Some(RepoEffects {
        summary,
        writes: writes(map)?,
        installer: script(map, "installer")?,
        uninstaller: script(map, "uninstaller")?,
        removal: text(map, "removal")?,
        notes: list(map, "notes")?,
        companions: list(map, "companions")?,
    })
}

/// A list field: absent is empty, present-but-not-a-list is a refusal.
///
/// `unwrap_or_default` could not tell those apart, so a `writes:` written as
/// a map — an easy thing to do by hand — disclosed no written paths at all
/// while the installer went on writing them. The block is a person's whole
/// account of what is about to change, and a field kendex could not read is
/// not a field with nothing in it.
///
/// Refusing the WHOLE declaration rather than the one field, because a
/// partial disclosure is the dangerous kind: it reads as complete.
fn list(map: &Map, key: &str) -> Option<Vec<String>> {
    match map.get(key) {
        None | Some(Value::Null) => Some(Vec::new()),
        // Every member, or none of it. `string_list` drops what it cannot
        // read, so a list with one map in it came back shorter and the block
        // printed a shorter list — the same fail-open as the wrong shape,
        // one level down, and harder to notice because what it produces
        // looks exactly like a correct answer.
        Some(Value::List(items)) if items.iter().any(|item| item.as_str().is_none()) => None,
        Some(_) => map.string_list(key),
    }
}

/// The written paths, each of which has to stay inside the repository.
///
/// A declaration is content from a catalog, and these strings are mapped
/// onto real locations for the block — `.git/...` against the repository's
/// common git directory, everything else against the project. A `..` hop or
/// an absolute path maps to somewhere else entirely, and one that climbed
/// out of the git directory and back in would have been announced as shared
/// by every work tree.
///
/// Refused rather than dropped, and the whole declaration with it: a block
/// missing one of the paths a package writes reads as the complete account
/// it is not.
fn writes(map: &Map) -> Option<Vec<String>> {
    let paths = list(map, "writes")?;
    let contained = paths.iter().all(|path| {
        let path = std::path::Path::new(path);
        path.components().all(|component| {
            matches!(
                component,
                std::path::Component::Normal(_) | std::path::Component::CurDir
            )
        })
    });
    contained.then_some(paths)
}

/// A scalar field, with the same rule.
fn text(map: &Map, key: &str) -> Option<Option<String>> {
    match map.get(key) {
        None | Some(Value::Null) => Some(None),
        Some(Value::Scalar(_)) => Some(scalar(map, key)),
        Some(_) => None,
    }
}

/// A script field: a scalar, and a path that stays inside the package.
///
/// The two failures are not the same failure. A wrong SHAPE means kendex
/// could not read what the package said, so the declaration is refused
/// whole. A path that leaves the package is read perfectly well and is
/// something kendex will not run: the script is dropped and the rest of the
/// declaration stands, so the block still says what the package does while
/// naming nothing to launch.
fn script(map: &Map, key: &str) -> Option<Option<String>> {
    match map.get(key) {
        None | Some(Value::Null) => Some(None),
        Some(Value::Scalar(_)) => Some(scalar(map, key).filter(|raw| inside(raw))),
        Some(_) => None,
    }
}

/// Whether the program a declaration names stays inside the package.
///
/// A declaration is content from a catalog, so an absolute path or a `..`
/// hop is a name kendex will not resolve. The caller drops the script rather
/// than refusing the declaration, which leaves the package with no installer
/// to run and its disclosure honest about that.
fn inside(raw: &str) -> bool {
    let (program, _) = split_script(raw);
    let path = std::path::Path::new(program);
    !program.is_empty()
        && path.components().all(|component| {
            matches!(
                component,
                std::path::Component::Normal(_) | std::path::Component::CurDir
            )
        })
}

fn scalar(map: &Map, key: &str) -> Option<String> {
    map.get(key)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|text| !text.is_empty())
        .map(str::to_owned)
}

/// A declared script split into the program and its arguments. Whitespace
/// separated, which is all a declaration needs: the arguments are the
/// package's own flags, never a path or a shell fragment.
pub(super) fn split_script(spec: &str) -> (&str, Vec<&str>) {
    let mut words = spec.split_whitespace();
    let program = words.next().unwrap_or_default();
    (program, words.collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    const DECLARED: &str = "---\nname: growth-guards\nrepo-effects:\n  summary: Arms git hooks.\n  writes:\n    - .git/hooks/pre-commit\n  installer: scripts/install-git-hooks\n  uninstaller: scripts/install-git-hooks --uninstall\n---\nbody\n";

    #[test]
    fn a_declaration_reads_whole() {
        let effects = declared(DECLARED).expect("declared");
        assert_eq!(effects.summary, "Arms git hooks.");
        assert_eq!(effects.writes, [".git/hooks/pre-commit"]);
        assert_eq!(
            effects.installer.as_deref(),
            Some("scripts/install-git-hooks")
        );
    }

    #[test]
    fn a_package_declaring_nothing_reads_as_nothing() {
        assert!(declared("---\nname: deploy\n---\nbody\n").is_none());
        assert!(declared("no frontmatter at all\n").is_none());
    }

    /// A summary is what the disclosure is made of; without one there is
    /// nothing to show, so there is nothing to authorize either.
    #[test]
    fn a_declaration_without_a_summary_is_not_a_declaration() {
        let text = "---\nname: x\nrepo-effects:\n  writes:\n    - .git/hooks/pre-commit\n---\n";
        assert!(declared(text).is_none());
    }

    /// A field kendex could not read is not a field with nothing in it.
    ///
    /// `unwrap_or_default` could not tell "absent" from "present and not a
    /// list", so a `writes:` written as a map — an easy thing to do by hand
    /// — disclosed no written paths while the installer went on writing
    /// them. One shape per field, because the fail-open was per field.
    #[test]
    fn a_field_of_the_wrong_shape_refuses_the_whole_declaration() {
        let wrong = [
            "  writes:\n    a: b\n",
            "  notes:\n    a: b\n",
            "  companions:\n    a: b\n",
            "  installer:\n    - scripts/run\n",
            "  uninstaller:\n    a: b\n",
            "  removal:\n    - by hand\n",
        ];
        for field in wrong {
            let text = format!("---\nname: x\nrepo-effects:\n  summary: s\n{field}---\nbody\n");
            assert!(
                declared(&text).is_none(),
                "a malformed field was read as empty: {field}"
            );
        }
    }

    /// A written path that leaves the repository is not a written path.
    ///
    /// These strings are mapped onto real locations for the block, so a
    /// `..` hop or an absolute path names somewhere else — and one that
    /// climbed out of the git directory and back in would have been
    /// announced as shared by every work tree of the repository.
    #[test]
    fn a_written_path_that_escapes_refuses_the_declaration() {
        let escaping = [
            ".git/../../elsewhere/hook",
            "/etc/profile",
            "../outside",
            "./.git/hooks/../../../x",
        ];
        for path in escaping {
            let text = format!(
                "---\nname: x\nrepo-effects:\n  summary: s\n  writes:\n    - \"{path}\"\n---\nbody\n"
            );
            assert!(
                declared(&text).is_none(),
                "an escaping written path was accepted: {path}"
            );
        }

        // The ordinary ones still read, `.git/` included — that is the
        // whole point of the mapping this guards.
        let good = "---\nname: x\nrepo-effects:\n  summary: s\n  writes:\n    - .git/hooks/pre-commit\n    - ./tools/guard\n---\nbody\n";
        let effects = declared(good).expect("contained paths read");
        assert_eq!(effects.writes.len(), 2);
    }

    /// A list with a member kendex cannot read is not a shorter list.
    ///
    /// `string_list` drops what it cannot read, so a `writes:` with one map
    /// among its paths came back short — and a short list of written paths
    /// is worse than none, because it reads as the complete account it is
    /// not.
    #[test]
    fn a_list_with_an_unreadable_member_refuses_the_declaration() {
        let mixed = [
            "  writes:\n    - .git/hooks/pre-commit\n    - a: b\n",
            "  notes:\n    - a real note\n    - a: b\n",
            "  companions:\n    - size-ratchet\n    - a: b\n",
        ];
        for field in mixed {
            let text = format!("---\nname: x\nrepo-effects:\n  summary: s\n{field}---\nbody\n");
            assert!(
                declared(&text).is_none(),
                "a list came back short instead of refusing: {field}"
            );
        }

        // And a list of scalars is still a list of scalars.
        let good = "---\nname: x\nrepo-effects:\n  summary: s\n  writes:\n    - .git/hooks/pre-commit\n    - .git/hooks/commit-msg\n---\nbody\n";
        let effects = declared(good).expect("a list of paths is readable");
        assert_eq!(effects.writes.len(), 2);
    }

    /// Absent stays absent. The refusal above must not turn every package
    /// that declares only a summary into one kendex cannot read.
    #[test]
    fn an_absent_field_is_absent_and_the_declaration_stands() {
        let text = "---\nname: x\nrepo-effects:\n  summary: s\n---\nbody\n";
        let effects = declared(text).expect("a summary alone is a declaration");
        assert_eq!(effects.summary, "s");
        assert!(effects.writes.is_empty());
        assert!(effects.notes.is_empty());
        assert!(effects.companions.is_empty());
        assert_eq!(effects.installer, None);
        assert_eq!(effects.uninstaller, None);
        assert_eq!(effects.removal, None);

        // An explicit null is absent too, not a shape kendex cannot read.
        let nulls =
            "---\nname: x\nrepo-effects:\n  summary: s\n  writes: ~\n  installer: ~\n---\nbody\n";
        let effects = declared(nulls).expect("an explicit null is absent");
        assert!(effects.writes.is_empty());
        assert_eq!(effects.installer, None);
    }

    /// A path that leaves the package is dropped, so nothing outside it is
    /// ever resolved as an installer.
    #[test]
    fn an_escaping_script_path_is_dropped() {
        for path in ["/bin/sh", "../../elsewhere/run", "scripts/../../run"] {
            let text =
                format!("---\nname: x\nrepo-effects:\n  summary: s\n  installer: {path}\n---\n");
            let effects = declared(&text).expect("declared");
            assert_eq!(effects.installer, None, "{path} was accepted");
        }
    }
}
