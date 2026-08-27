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
    if !only_known(map) {
        return None;
    }
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

/// The fields a declaration may have. Every one of them is read above.
const FIELDS: [&str; 7] = [
    "summary",
    "writes",
    "installer",
    "uninstaller",
    "removal",
    "notes",
    "companions",
];

/// Whether every key in the declaration is one kendex knows.
///
/// A key kendex does not know is a key it did not read, and the ways to
/// write one are all typing accidents: `writse:` next to `writes:` is a
/// package that declares the paths it writes and a block that names none of
/// them, while the installer writes them anyway. Nothing distinguishes that
/// from a package which genuinely writes nothing.
///
/// So the same rule as every field above — refused whole, not read short.
/// It costs a package nothing: this is a fixed set of seven keys with no
/// extension point, and a declaration carrying an eighth is one somebody
/// mistyped.
fn only_known(map: &Map) -> bool {
    map.entries().all(|(key, _)| FIELDS.contains(&key))
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
    let Some(value) = map.get(key) else {
        return Some(Vec::new());
    };
    let Value::List(items) = value else {
        // Absent is empty; anything else present has to be a list.
        //
        // `string_list` also accepts a scalar and splits it on commas, which
        // is a convenience these fields must not have: every one of them is
        // a list of PATHS, and a comma is a character a filename may
        // contain. A package writing `.git/hooks/a,b` would have had it read
        // as two files that do not exist, in the block a person authorizes.
        return matches!(value, Value::Null).then(Vec::new);
    };
    items
        .iter()
        .map(|item| {
            let text = item.as_str()?.trim();
            // And every member has to say something. `string_list` drops the
            // empty ones, which comes back as a shorter list — the fail-open
            // this whole reader exists to refuse, and the worst kind because
            // what it produces looks exactly like a correct answer.
            (!text.is_empty()).then(|| text.to_owned())
        })
        .collect()
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
mod tests;
