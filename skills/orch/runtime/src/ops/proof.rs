//! Validation proof coverage under the project declaration.

use serde::{Deserialize, Serialize};

use crate::settings::ValidateSettings;
use crate::state::{Stage, StageKind, StageOutcome, ValidateMode};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Need {
    Round,
    Submit,
    Restack,
    Recovery,
}

impl Need {
    /// The need's word.
    pub fn word(self) -> &'static str {
        match self {
            Need::Round => "round",
            Need::Submit => "submit",
            Need::Restack => "restack",
            Need::Recovery => "recovery",
        }
    }
}

/// The project's declaration as the reader admits rows by it: the whole
/// battery's command, the range command where declared, whether a CI
/// context is declared, and the finding prefix every row must have run
/// with. A row that ran another command text than the declaration's for
/// its mode proves nothing under this declaration.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Declaration {
    pub cmd: String,
    pub range_cmd: Option<String>,
    pub docs_cmd: Option<String>,
    pub ci_declared: bool,
    pub finding_prefix: String,
}

impl Declaration {
    /// The declaration the settings reader holds.
    pub fn of(settings: &ValidateSettings) -> Declaration {
        Declaration {
            cmd: settings.cmd.clone().unwrap_or_default(),
            range_cmd: settings.range_cmd.clone(),
            docs_cmd: settings
                .selection_cmd
                .clone()
                .or_else(|| crate::validate::text_cmd(settings)),
            ci_declared: settings.ci_context.is_some(),
            finding_prefix: settings.finding_prefix.clone().unwrap_or_default(),
        }
    }

    /// The modes the declaration admits as local proof for `need`, each
    /// with the command text a row of that mode must have run. The whole
    /// battery always; the range command for a round's own need where
    /// declared, and for publication where declared with no CI gate.
    fn admitted(&self, need: Need) -> Vec<(ValidateMode, &str)> {
        let mut modes = vec![(ValidateMode::Full, self.cmd.as_str())];
        if let Some(cmd) = &self.docs_cmd {
            modes.push((ValidateMode::Docs, cmd.as_str()));
        }
        if let Some(range) = &self.range_cmd
            && (matches!(need, Need::Round | Need::Recovery) || !self.ci_declared)
        {
            modes.push((ValidateMode::Range, range.as_str()));
        }
        modes
    }

    /// The narrowest mode the declaration names: what a `missing` answer
    /// lacks.
    fn narrowest(&self) -> ValidateMode {
        if self.ci_declared {
            ValidateMode::Ci
        } else if self.range_cmd.is_some() {
            ValidateMode::Range
        } else {
            ValidateMode::Full
        }
    }
}

/// The read: the need, the tree it asks about, the head that tree is
/// committed at (a restack reads its recorded skip by it), the base the
/// need judges from (a row over exactly that base covers it without a
/// further read), and the round whose rows alone a recovery reads.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReadProof {
    pub need: Need,
    pub tree: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub head: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub base: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub round: Option<String>,
}

/// A recorded restack skip (`merge-pr-restack.md` step 2, its one writer):
/// the restacked head and the HEAD of the run whose tree the restack is
/// equivalent to. The other fields of the record stay unread.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RestackSkip {
    pub head: String,
    pub validated_head: String,
}

/// The reader's word.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Verdict {
    Complete,
    Pending,
    Missing,
}

/// One row of the answer: the stage's identity and the proof facts the
/// verdict rests on.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProofRow {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub round_id: Option<String>,
    pub run_dir: String,
    pub tree: String,
    pub head: String,
    pub mode: ValidateMode,
    pub base: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub class_base: Option<String>,
    pub selection: String,
    pub start: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub end: Option<u64>,
    /// The stage's place in `stages[]`: the order of two rows started in
    /// the same second.
    #[serde(skip)]
    pub index: usize,
}

/// What a `missing` answer lacks: a pass at the tree in the mode.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Lacks {
    pub tree: String,
    pub mode: ValidateMode,
}

/// The answer.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProofRead {
    pub need: Need,
    pub tree: String,
    pub proof: Verdict,
    /// The rows the verdict rests on: the chain that proves the tree, the
    /// pending `ci` row, or none.
    pub rows: Vec<ProofRow>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lacks: Option<Lacks>,
    /// The recorded skip the rows were read through, where the restack's
    /// head has one and the proof is its validated run's.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub skip: Option<RestackSkip>,
}

/// A row's proof facts, or `None` where the stage is not a proof row at
/// all: not a validate stage, or one with no proof recorded.
fn row_of((index, stage): (usize, &Stage)) -> Option<ProofRow> {
    let proof = stage.proof.as_ref()?;
    if stage.kind != StageKind::Validate {
        return None;
    }
    Some(ProofRow {
        round_id: stage.round_id.clone(),
        run_dir: stage.run_dir.clone().unwrap_or_default(),
        tree: proof.tree.clone(),
        head: proof.head.clone(),
        mode: proof.mode,
        base: proof.base.clone(),
        class_base: proof.class_base.clone(),
        selection: proof.selection.clone(),
        start: stage.start,
        end: stage.end,
        index,
    })
}

/// Whether the stage is the tree's own local evidence that did not pass: a
/// validate row at `tree` that ran its own command (not a reuse, and not a
/// `ci` row, which ran nothing locally) and is red, lost, stopped,
/// bound-ended or still open.
fn unpassed_at(tree: &str, s: &Stage) -> bool {
    s.kind == StageKind::Validate
        && s.proof
            .as_ref()
            .is_some_and(|p| p.tree == tree && p.mode != ValidateMode::Ci && p.reused.is_none())
        && (s.end.is_none() || s.outcome != Some(StageOutcome::Pass))
}

/// A row at the tree that did not pass and started no earlier than the
/// pass voids it: within one start second the records cannot prove which
/// came first.
fn voided(stages: &[Stage], tree: &str, pass: &ProofRow) -> bool {
    stages
        .iter()
        .any(|s| unpassed_at(tree, s) && s.start >= pass.start)
}

/// Whether the row is a pass that ran its own command: closed `pass`, not
/// a reuse of an earlier row, scoped only for a docs-only snapshot, and
/// run with the declared finding prefix.
fn own_pass(stage: &Stage, declaration: &Declaration) -> bool {
    stage.end.is_some()
        && stage.outcome == Some(StageOutcome::Pass)
        && stage.proof.as_ref().is_some_and(|p| {
            (p.mode != ValidateMode::Docs || p.docs_only)
                && p.reused.is_none()
                && (!p.scoped || (p.mode == ValidateMode::Docs && p.docs_only))
                && p.finding_prefix == declaration.finding_prefix
        })
}

/// A `full` row that covers its tree whole: its command reported the whole
/// battery, or its class was read over the whole branch.
fn whole(row: &ProofRow) -> bool {
    row.mode == ValidateMode::Docs
        || (row.mode == ValidateMode::Full
            && (row.selection == "battery" || row.class_base.is_none()))
}

/// The base a partial row covers from: a range row's base, a full row's
/// class base. Empty is no base, which covers nothing.
fn partial_base(row: &ProofRow) -> Option<&str> {
    let base = match row.mode {
        ValidateMode::Range => row.base.as_str(),
        ValidateMode::Full => row.class_base.as_deref().unwrap_or_default(),
        ValidateMode::Ci | ValidateMode::Docs => "",
    };
    (!base.is_empty()).then_some(base)
}

/// The reader. `tree_of` reads a base commit's committed tree, the one
/// read a chain across rounds needs; `None` is a base that cannot be read,
/// which is never coverage.
pub fn read(
    stages: &[Stage],
    skips: &[RestackSkip],
    r: &ReadProof,
    declaration: &Declaration,
    tree_of: &mut dyn FnMut(&str) -> Option<String>,
) -> ProofRead {
    let mut reader = Reader {
        stages,
        round: match r.need {
            Need::Recovery => r.round.as_deref(),
            Need::Round | Need::Submit | Need::Restack => None,
        },
        admitted: declaration.admitted(r.need),
        declaration,
        tree_of,
    };
    let answer = |proof: Verdict, rows: Vec<ProofRow>, skip: Option<RestackSkip>| ProofRead {
        need: r.need,
        tree: r.tree.clone(),
        proof,
        rows,
        lacks: match proof {
            Verdict::Missing => Some(Lacks {
                tree: r.tree.clone(),
                mode: declaration.narrowest(),
            }),
            Verdict::Complete | Verdict::Pending => None,
        },
        skip,
    };
    if let Some(rows) = reader.covers(&r.tree, r.base.as_deref(), &mut vec![r.tree.clone()]) {
        return answer(Verdict::Complete, rows, None);
    }
    if r.need == Need::Restack
        && let Some(head) = r.head.as_deref()
        && let Some(skip) = skips.iter().rev().find(|s| s.head == head)
        && !stages.iter().any(|s| unpassed_at(&r.tree, s))
    {
        let trees: Vec<String> = reader
            .rows()
            .filter(|row| row.head == skip.validated_head && !row.tree.is_empty())
            .map(|row| row.tree)
            .collect();
        for tree in trees {
            if let Some(rows) = reader.covers(&tree, None, &mut vec![tree.clone()]) {
                return answer(Verdict::Complete, rows, Some(skip.clone()));
            }
        }
    }
    if let Some(row) = reader.pending(&r.tree) {
        return answer(Verdict::Pending, vec![row], None);
    }
    answer(Verdict::Missing, Vec::new(), None)
}

/// One read's rows, admission and the tree read it chains through.
struct Reader<'a> {
    stages: &'a [Stage],
    /// A recovery reads the round's own rows alone.
    round: Option<&'a str>,
    admitted: Vec<(ValidateMode, &'a str)>,
    declaration: &'a Declaration,
    tree_of: &'a mut dyn FnMut(&str) -> Option<String>,
}

impl Reader<'_> {
    /// The item's own passes under the admission, newest first: closed
    /// `pass`, their own command, in an admitted mode running that mode's
    /// declared command, of the recovery's round where one is named.
    fn rows(&self) -> impl Iterator<Item = ProofRow> + '_ {
        let mut rows: Vec<ProofRow> = self
            .stages
            .iter()
            .enumerate()
            .filter(|(_, s)| own_pass(s, self.declaration))
            .filter(|(_, s)| {
                self.round
                    .is_none_or(|round| s.round_id.as_deref() == Some(round))
            })
            .filter(|(_, s)| {
                s.proof.as_ref().is_some_and(|p| {
                    self.admitted
                        .iter()
                        .any(|(mode, cmd)| p.mode == *mode && p.cmd == *cmd)
                })
            })
            .filter_map(row_of)
            .collect();
        rows.sort_by_key(|row| std::cmp::Reverse((row.start, row.index)));
        rows.into_iter()
    }

    /// The rows that prove `tree` for a need judged from `base`: a whole
    /// row at the tree, a partial row over the need's base, or a partial
    /// row whose base's committed tree is itself proven (`visited` holds
    /// the trees on the chain, so a base whose tree is already being read
    /// ends it). `None` where nothing does.
    fn covers(
        &mut self,
        tree: &str,
        base: Option<&str>,
        visited: &mut Vec<String>,
    ) -> Option<Vec<ProofRow>> {
        if tree.is_empty() {
            return None;
        }
        let rows: Vec<ProofRow> = self.rows().filter(|row| row.tree == tree).collect();
        for row in rows {
            if voided(self.stages, tree, &row) {
                continue;
            }
            if whole(&row) {
                return Some(vec![row]);
            }
            let Some(from) = partial_base(&row) else {
                continue;
            };
            if base == Some(from) {
                return Some(vec![row]);
            }
            let Some(next) = (self.tree_of)(from) else {
                continue;
            };
            if next.is_empty() || visited.contains(&next) {
                continue;
            }
            visited.push(next.clone());
            if let Some(mut chain) = self.covers(&next, base, visited) {
                chain.insert(0, row);
                return Some(chain);
            }
        }
        None
    }

    /// A `ci` row at `tree` closed `pass`, CI pending on the published
    /// head, not voided by a later local row that did not pass.
    fn pending(&self, tree: &str) -> Option<ProofRow> {
        self.stages
            .iter()
            .enumerate()
            .filter(|(_, s)| {
                s.kind == StageKind::Validate
                    && s.end.is_some()
                    && s.outcome == Some(StageOutcome::Pass)
                    && self
                        .round
                        .is_none_or(|round| s.round_id.as_deref() == Some(round))
                    && s.proof.as_ref().is_some_and(|p| {
                        p.mode == ValidateMode::Ci && p.tree == tree && !tree.is_empty()
                    })
            })
            .filter_map(row_of)
            .filter(|row| !voided(self.stages, tree, row))
            .max_by_key(|row| (row.start, row.index))
    }
}

#[allow(
    clippy::disallowed_methods,
    reason = "restack equivalence reads git in a private object store and the project's changelog classifier"
)]
pub fn restack(
    worktree: &std::path::Path,
    base: &str,
    env: &crate::ops::Env,
) -> crate::error::Result<(String, i32)> {
    use crate::validate::files;
    use agent_runtime::host::{self, Place};
    use std::ffi::OsStr;
    use std::path::Path;
    use std::time::Duration;
    let retest = |cause: &str, path: Option<&str>, dir: Option<&Path>| {
        (
            format!(
                "restack=retest cause={cause}{}{}",
                path.map(|p| format!(" path={p}")).unwrap_or_default(),
                dir.map(|d| format!(" run-dir={}", d.display()))
                    .unwrap_or_default()
            ),
            1,
        )
    };
    let run = match files::last_pass(worktree)? {
        files::LastPass::Pass(run) => run,
        files::LastPass::Red(dir) => return Ok(retest("newer-red", None, Some(&dir))),
        files::LastPass::None => return Ok(retest("no-passing-run", None, None)),
    };
    let dir = Some(run.dir.as_path());
    let scratch = crate::validate::Scratch::new(env)?;
    let git_read = |args: &[&str]| {
        crate::validate::git(worktree, "restack", args, &mut String::new())
            .ok()
            .flatten()
            .map(|s| s.trim().to_owned())
    };
    let Some(new_base) = git_read(&["rev-parse", "--verify", "-q", &format!("{base}^{{commit}}")])
    else {
        return Ok(retest("base-unreadable", None, dir));
    };
    let Some(head) = git_read(&["rev-parse", "--verify", "-q", "HEAD^{commit}"]) else {
        return Ok(retest("head-unreadable", None, dir));
    };
    let Some(objects) = git_read(&[
        "rev-parse",
        "--path-format=absolute",
        "--git-path",
        "objects",
    ]) else {
        return Ok(retest("object-missing", None, dir));
    };
    let private = scratch.0.join("objects");
    std::fs::create_dir(&private).map_err(|e| files::unreadable("objects", e))?;
    let store = [
        ("GIT_OBJECT_DIRECTORY", private.as_os_str()),
        ("GIT_ALTERNATE_OBJECT_DIRECTORIES", OsStr::new(&objects)),
        ("GIT_AUTHOR_NAME", OsStr::new("restack-skip")),
        ("GIT_AUTHOR_EMAIL", OsStr::new("restack-skip@localhost")),
        ("GIT_COMMITTER_NAME", OsStr::new("restack-skip")),
        ("GIT_COMMITTER_EMAIL", OsStr::new("restack-skip@localhost")),
    ];
    let call = |program, executable: &Path, args: &[&str], input: Option<&[u8]>| {
        let place = Place {
            cwd: Some(worktree),
            env: &store,
        };
        match input {
            Some(bytes) => host::run_tagged_fed(
                "proof",
                program,
                executable,
                "restack",
                args,
                place,
                bytes,
                Duration::from_secs(120),
            ),
            None => host::run_tagged_in(
                "proof",
                program,
                executable,
                "restack",
                args,
                place,
                Duration::from_secs(120),
            ),
        }
    };
    let git = |args: &[&str]| call("git", Path::new("git"), args, None).ok();
    let Some(validated) = git(&[
        "commit-tree",
        run.get("tree"),
        "-p",
        run.get("head"),
        "-m",
        "restack: validated",
    ])
    .filter(|o| o.status.success()) else {
        return Ok(retest("object-missing", None, dir));
    };
    let validated = host::stdout_text(&validated);
    let Some(merged) = git(&[
        "-c",
        "merge.conflictStyle=merge",
        "merge-tree",
        "--write-tree",
        "-z",
        &new_base,
        &validated,
    ]) else {
        return Ok(retest("merge-failed", None, dir));
    };
    if !matches!(merged.status.code(), Some(0 | 1)) {
        return Ok(retest("merge-failed", None, dir));
    }
    let (tree, conflicts) = match merge_output(&merged.stdout) {
        Ok(out) => out,
        Err((cause, path)) => return Ok(retest(cause, path.as_deref(), dir)),
    };
    let Some(diff) = git(&[
        "diff-tree",
        "-r",
        "-z",
        "--no-renames",
        &tree,
        &format!("{head}^{{tree}}"),
    ])
    .filter(|o| o.status.success()) else {
        return Ok(retest("diff-failed", None, dir));
    };
    let tokens: Vec<_> = diff
        .stdout
        .split(|b| *b == 0)
        .filter(|s| !s.is_empty())
        .collect();
    if !tokens.len().is_multiple_of(2) {
        return Ok(retest("diff-failed", None, dir));
    }
    for pair in tokens.chunks(2) {
        let Ok(meta) = std::str::from_utf8(pair[0]) else {
            return Ok(retest("path-shape", None, dir));
        };
        let Ok(path) = std::str::from_utf8(pair[1]) else {
            return Ok(retest("path-shape", None, dir));
        };
        let words: Vec<_> = meta.trim_start_matches(':').split_whitespace().collect();
        if words.len() != 5
            || words[4] != "M"
            || words[0] != words[1]
            || !matches!(words[0], "100644" | "100755")
        {
            return Ok(retest("path-shape", Some(path), dir));
        }
        if !conflicts.iter().any(|(p, _)| p == path) {
            return Ok(retest("path-unconflicted", Some(path), dir));
        }
    }
    if conflicts.is_empty() {
        return Ok((
            format!(
                "restack=skip condition=no-conflict run-dir={} validated-head={} head={head} paths=none",
                run.dir.display(),
                run.get("head")
            ),
            0,
        ));
    }
    let classifier = worktree.join(".agents/skills/commit-guards/scripts/changelog-entries");
    let mut args = vec!["--classify"];
    args.extend(conflicts.iter().map(|(p, _)| p.as_str()));
    let kinds = match call("changelog-entries", &classifier, &args, None) {
        Ok(out) if out.status.success() => host::stdout_text(&out),
        Err(agent_runtime::Error::NotStarted { .. }) => {
            return Ok(retest("classifier-missing", None, dir));
        }
        _ => return Ok(retest("classifier-failed", None, dir)),
    };
    let kinds: Vec<_> = kinds.lines().collect();
    if kinds.len() != conflicts.len() {
        return Ok(retest("classifier-failed", None, dir));
    }
    for ((path, mode), kind) in conflicts.iter().zip(kinds) {
        let Some((kind, named)) = kind.split_once('\t') else {
            return Ok(retest("classifier-failed", None, dir));
        };
        if named != path {
            return Ok(retest("classifier-failed", None, dir));
        }
        if !matches!(kind, "record" | "fragment" | "version") {
            return Ok(retest("unclassified", Some(path), dir));
        }
        let Some(entry) =
            git(&["ls-tree", "--full-tree", &head, "--", path]).filter(|o| o.status.success())
        else {
            return Ok(retest("path-shape", Some(path), dir));
        };
        if host::stdout_text(&entry).split_whitespace().next() != Some(mode.as_str()) {
            return Ok(retest("path-shape", Some(path), dir));
        }
        let (Some(merged), Some(current)) = (
            git(&["cat-file", "blob", &format!("{tree}:{path}")]).filter(|o| o.status.success()),
            git(&["cat-file", "blob", &format!("{head}:{path}")]).filter(|o| o.status.success()),
        ) else {
            return Ok(retest("object-missing", Some(path), dir));
        };
        if kind == "version" {
            let unversion = |bytes: &[u8]| {
                call(
                    "changelog-entries",
                    &classifier,
                    &["--unversion"],
                    Some(bytes),
                )
                .ok()
                .filter(|o| o.status.success())
                .map(|o| o.stdout)
            };
            let Some(current) = unversion(&current.stdout) else {
                return Ok(retest("classifier-failed", Some(path), dir));
            };
            for side in [1, 2] {
                let Some(merged) = merged_side(&merged.stdout, side) else {
                    return Ok(retest("hunk", Some(path), dir));
                };
                let Some(merged) = unversion(&merged) else {
                    return Ok(retest("classifier-failed", Some(path), dir));
                };
                if merged != current {
                    return Ok(retest("hunk", Some(path), dir));
                }
            }
        } else if changelog_rest(&merged.stdout, true)
            .zip(changelog_rest(&current.stdout, false))
            .is_none_or(|(a, b)| a != b)
        {
            return Ok(retest("hunk", Some(path), dir));
        }
    }
    Ok((
        format!(
            "restack=skip condition=version-only run-dir={} validated-head={} head={head} paths={}",
            run.dir.display(),
            run.get("head"),
            conflicts
                .iter()
                .map(|(p, _)| p.as_str())
                .collect::<Vec<_>>()
                .join(",")
        ),
        0,
    ))
}

type MergeOutput = (String, Vec<(String, String)>);
fn merge_output(bytes: &[u8]) -> std::result::Result<MergeOutput, (&'static str, Option<String>)> {
    let bad = || ("merge-failed", None);
    let tokens: Vec<_> = bytes.split(|b| *b == 0).collect();
    let tree = std::str::from_utf8(tokens.first().ok_or_else(bad)?)
        .map_err(|_| bad())?
        .to_owned();
    if tree.is_empty() {
        return Err(bad());
    }
    let mut conflicts: Vec<(String, String)> = Vec::new();
    let mut index = 1;
    while index < tokens.len() && !tokens[index].is_empty() {
        let token = std::str::from_utf8(tokens[index]).map_err(|_| bad())?;
        let (meta, path) = token.split_once('\t').ok_or_else(bad)?;
        let mode = meta.split_whitespace().next().ok_or_else(bad)?;
        let conflict = || ("conflict-kind", Some(path.to_owned()));
        if !matches!(mode, "100644" | "100755") {
            return Err(conflict());
        }
        if let Some((_, old)) = conflicts.iter().find(|(p, _)| p == path) {
            if old != mode {
                return Err(conflict());
            }
        } else {
            conflicts.push((path.into(), mode.into()));
        }
        index += 1;
    }
    index += 1;
    while index < tokens.len() && !tokens[index].is_empty() {
        let count = std::str::from_utf8(tokens[index])
            .map_err(|_| bad())?
            .parse::<usize>()
            .map_err(|_| bad())?;
        let first = tokens
            .get(index + 1)
            .and_then(|p| std::str::from_utf8(p).ok())
            .map(str::to_owned);
        index = index.checked_add(count + 1).ok_or_else(bad)?;
        let kind = std::str::from_utf8(tokens.get(index).ok_or_else(bad)?).map_err(|_| bad())?;
        if kind.starts_with("CONFLICT") && kind != "CONFLICT (contents)" {
            return Err(("conflict-kind", first));
        }
        tokens.get(index + 1).ok_or_else(bad)?;
        index += 2;
    }
    Ok((tree, conflicts))
}

fn changelog_rest(bytes: &[u8], markers: bool) -> Option<Vec<String>> {
    let text = std::str::from_utf8(bytes).ok()?;
    let mut inside = false;
    let mut kept = Vec::new();
    for line in text.lines() {
        if markers && !inside && (line == "<<<<<<<" || line.starts_with("<<<<<<< ")) {
            inside = true;
            continue;
        }
        if inside && (line == "=======" || line.starts_with("|||||||")) {
            continue;
        }
        if inside && (line == ">>>>>>>" || line.starts_with(">>>>>>> ")) {
            inside = false;
            continue;
        }
        let allowed = line.trim().is_empty()
            || line.starts_with([' ', '\t'])
            || line.trim_start_matches('#').starts_with([' ', '\t']) && line.starts_with('#')
            || ["- ", "* ", "+ ", "-\t", "*\t", "+\t"]
                .iter()
                .any(|p| line.starts_with(p));
        if allowed {
            continue;
        }
        if inside {
            return None;
        }
        kept.push(line.to_owned());
    }
    (!inside).then_some(kept)
}

fn merged_side(bytes: &[u8], side: u8) -> Option<Vec<u8>> {
    let text = std::str::from_utf8(bytes).ok()?;
    let mut region = 0;
    let mut out = String::new();
    for line in text.lines() {
        if region == 0 && (line == "<<<<<<<" || line.starts_with("<<<<<<< ")) {
            region = 1;
            continue;
        }
        if region == 1 && line == "=======" {
            region = 2;
            continue;
        }
        if region != 0 && (line == ">>>>>>>" || line.starts_with(">>>>>>> ")) {
            if region != 2 {
                return None;
            }
            region = 0;
            continue;
        }
        if region == 0 || region == side {
            out.push_str(line);
            out.push('\n')
        }
    }
    (region == 0).then(|| out.into_bytes())
}

/// One hop of a `kendex-rebase-map`: the rewrite's old commits to their new
/// ones (`dropped` where the patch was already upstream), in the order the
/// file lists them, a repeated old commit taking its last value in its first
/// place.
pub type Hop = Vec<(String, String)>;

/// Why a map cannot be read whole: the key the worktree skill's grammar
/// names and the line it stopped on.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MapUnreadable {
    pub cause: &'static str,
    pub line: usize,
}

/// The hops of a `kendex-rebase-map`, read whole before any is applied: a
/// `rebase-unmapped:` line anywhere refuses first, since no mapping repairs
/// that rewrite; then each `rebase-hop:` opens a hop whose `rebase-map: OLD
/// NEW` lines follow it, and anything else, a mapping before a boundary or a
/// hop with no mapping refuses.
pub fn hops(text: &str) -> std::result::Result<Vec<Hop>, MapUnreadable> {
    let refuse = |cause, line| Err(MapUnreadable { cause, line });
    if let Some(n) = text
        .lines()
        .position(|l| l.starts_with("rebase-unmapped: "))
    {
        return refuse("rebase-unmapped", n + 1);
    }
    let valid = |s: &str| {
        s.len() == 40
            && s.bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    };
    let mut hops: Vec<Hop> = Vec::new();
    let mut open: Option<usize> = None;
    let mut last = 0;
    for (index, line) in text.lines().enumerate() {
        let n = index + 1;
        last = n;
        if line == "rebase-hop:" {
            if let Some(at) = open
                && hops.last().is_some_and(Vec::is_empty)
            {
                return refuse("restack-map-grammar", at);
            }
            hops.push(Vec::new());
            open = Some(n);
        } else if let Some(rest) = line.strip_prefix("rebase-map: ") {
            let Some(hop) = hops.last_mut().filter(|_| open.is_some()) else {
                return refuse("restack-map-grammar", n);
            };
            let mut words = rest.split(' ');
            let old = words.next().unwrap_or("");
            let new = words.collect::<Vec<_>>().join(" ");
            if !valid(old) || !(valid(&new) || new == "dropped") {
                return refuse("map-sha", n);
            }
            match hop.iter_mut().find(|(o, _)| o == old) {
                Some(entry) => entry.1 = new,
                None => hop.push((old.to_owned(), new)),
            }
        } else {
            return refuse("restack-map-grammar", n);
        }
    }
    match (open, hops.last()) {
        (None, _) => refuse("restack-map-grammar", last.max(1)),
        (Some(at), Some(hop)) if hop.is_empty() => refuse("restack-map-grammar", at),
        _ => Ok(hops),
    }
}

/// A recorded commit through one hop: every mapping whose old commit the
/// recorded prefix starts is compared against the commit as the hop found
/// it, never another mapping's output, and the last one wins; a new commit
/// is cut to the recorded length, and a dropped one marked
/// `dropped:<recorded>` so no later hop reads it as live.
pub fn remap(recorded: &str, hop: &Hop) -> String {
    let mut out = recorded.to_owned();
    for (old, new) in hop {
        if old.starts_with(recorded) {
            out = if new == "dropped" {
                format!("dropped:{recorded}")
            } else {
                new[..recorded.len().min(new.len())].to_owned()
            };
        }
    }
    out
}

pub(crate) fn project_rebase(text: &str, sha: &str) -> crate::error::Result<String> {
    let hops = hops(text)
        .map_err(|e| crate::validate::files::unreadable("rebase-map-unreadable", e.cause))?;
    Ok(hops
        .iter()
        .fold(sha.to_owned(), |sha, hop| remap(&sha, hop)))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::state::Proof;

    fn proof(mode: ValidateMode, tree: &str, base: &str) -> Proof {
        Proof {
            tree: tree.into(),
            head: format!("head-{tree}"),
            base: base.into(),
            mode,
            cause: None,
            caller: "dev".into(),
            cmd: match mode {
                ValidateMode::Full => "full".into(),
                ValidateMode::Range => "range".into(),
                ValidateMode::Ci => "range".into(),
                ValidateMode::Docs => "docs".into(),
            },
            class: "standard".into(),
            docs_only: false,
            paths_hash: String::new(),
            scoped: false,
            selection: "all".into(),
            finding_prefix: String::new(),
            timeout_secs: 20,
            poll_secs: 1,
            cap_secs: 31,
            class_base: (mode == ValidateMode::Range).then(|| base.to_owned()),
            ci_fallback: None,
            ci_event: None,
            class_fallback: None,
            reused: None,
        }
    }

    /// A stage as the file holds it, read through the record's own
    /// deserializer, so the row names only the fields it plants.
    fn stage(start: u64, outcome: Option<StageOutcome>, proof: Proof) -> Stage {
        let mut row = serde_json::json!({
            "kind": "validate",
            "round_id": "r",
            "start": start,
            "end": outcome.map(|_| start + 1),
            "run_dir": format!("/w/tmp/dev-validate-{start}"),
            "proof": proof,
        });
        if let Some(outcome) = outcome {
            row["outcome"] = serde_json::json!(outcome);
        }
        serde_json::from_value(row).unwrap()
    }

    fn range_declared() -> Declaration {
        Declaration {
            cmd: "full".into(),
            range_cmd: Some("range".into()),
            docs_cmd: None,
            ci_declared: false,
            finding_prefix: String::new(),
        }
    }

    fn ask(need: Need, tree: &str, base: Option<&str>) -> ReadProof {
        ReadProof {
            need,
            tree: tree.into(),
            head: None,
            base: base.map(str::to_owned),
            round: Some("r".into()),
        }
    }

    #[test]
    fn a_range_row_over_another_base_chains_through_that_bases_tree_to_a_whole_row() {
        let stages = [
            stage(
                10,
                Some(StageOutcome::Pass),
                proof(ValidateMode::Full, "t0", ""),
            ),
            stage(
                20,
                Some(StageOutcome::Pass),
                proof(ValidateMode::Range, "t1", "h0"),
            ),
        ];
        let mut tree_of = |commit: &str| (commit == "h0").then(|| "t0".to_owned());
        let read = read(
            &stages,
            &[],
            &ask(Need::Submit, "t1", Some("mb")),
            &range_declared(),
            &mut tree_of,
        );
        assert_eq!(read.proof, Verdict::Complete);
        assert_eq!(
            read.rows
                .iter()
                .map(|r| r.tree.as_str())
                .collect::<Vec<_>>(),
            ["t1", "t0"]
        );
        // The base's tree unread: never coverage.
        let read = read_with_no_tree(&stages, &ask(Need::Submit, "t1", Some("mb")));
        assert_eq!(read.proof, Verdict::Missing);
        assert_eq!(
            read.lacks,
            Some(Lacks {
                tree: "t1".into(),
                mode: ValidateMode::Range
            })
        );
    }

    fn read_with_no_tree(stages: &[Stage], r: &ReadProof) -> ProofRead {
        read(stages, &[], r, &range_declared(), &mut |_| None)
    }

    #[test]
    fn a_chain_that_returns_to_a_tree_already_read_ends_there() {
        let stages = [
            stage(
                10,
                Some(StageOutcome::Pass),
                proof(ValidateMode::Range, "t0", "h1"),
            ),
            stage(
                20,
                Some(StageOutcome::Pass),
                proof(ValidateMode::Range, "t1", "h0"),
            ),
        ];
        let mut tree_of = |commit: &str| match commit {
            "h0" => Some("t0".to_owned()),
            "h1" => Some("t1".to_owned()),
            _ => None,
        };
        let read = read(
            &stages,
            &[],
            &ask(Need::Submit, "t1", Some("mb")),
            &range_declared(),
            &mut tree_of,
        );
        assert_eq!(read.proof, Verdict::Missing);
    }

    #[test]
    fn a_recovery_reads_the_rounds_own_rows_and_a_pass_after_its_fail_is_not_voided() {
        let mut other = stage(
            30,
            Some(StageOutcome::Pass),
            proof(ValidateMode::Full, "t", ""),
        );
        other.round_id = Some("other".into());
        let stages = [
            stage(
                10,
                Some(StageOutcome::Fail),
                proof(ValidateMode::Range, "t", "b"),
            ),
            stage(
                20,
                Some(StageOutcome::Pass),
                proof(ValidateMode::Range, "t", "b"),
            ),
            other,
        ];
        let read = read_with_no_tree(&stages, &ask(Need::Recovery, "t", Some("b")));
        assert_eq!(read.proof, Verdict::Complete);
        assert_eq!(read.rows[0].run_dir, "/w/tmp/dev-validate-20");
        // The other round's row alone proves nothing for this round.
        let read = read_with_no_tree(&stages[2..], &ask(Need::Recovery, "t", Some("b")));
        assert_eq!(read.proof, Verdict::Missing);
    }

    #[test]
    fn an_open_later_row_at_the_tree_voids_the_pass() {
        let stages = [
            stage(
                10,
                Some(StageOutcome::Pass),
                proof(ValidateMode::Full, "t", ""),
            ),
            stage(20, None, proof(ValidateMode::Full, "t", "")),
        ];
        assert_eq!(
            read_with_no_tree(&stages, &ask(Need::Round, "t", None)).proof,
            Verdict::Missing
        );
    }
}
