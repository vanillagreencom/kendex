//! `record-qa-decision`: the QA routing of a review's verdict pass, recorded
//! as the item's `qa_decision`.
//!
//! The scan collects the round's signals over `BASE...HEAD` in the worktree:
//! the dev round's `qa_labels`, a diff line matching unsafe code or atomics,
//! a changed path a `QA_PERF_PATHS` or `QA_UI_PATHS` glob matches; a read
//! that fails adds the signal it would have decided. The review's judgments
//! then add or drop signals in order, each with its reason. A performance
//! signal gates only where the repository declares the review's runner,
//! workload and baseline; without them it is recorded advisory, so it is
//! never dropped unseen and never delegated to a review that cannot give a
//! verdict.
use std::path::{Path, PathBuf};
use std::time::Duration;

use agent_runtime::host::{self, Place};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

use super::{loaded, reread};
use crate::error::{Error, Result};
use crate::settings::Settings;
use crate::state::{self, Locking};

const TAG: &str = "qa";
const READ: Duration = Duration::from_secs(120);
/// The settings that declare the performance review a signal is delegated
/// to; any one unset leaves the signal advisory.
const PERF_DECLARATION: [&str; 3] = ["QA_PERF_RUNNER", "QA_PERF_WORKLOAD", "QA_PERF_BASELINE"];
const SAFETY_PATTERN: &str = "unsafe |Ordering::|Atomic(U|I|Bool|Ptr)";

/// The four QA signals and the agent each is delegated to.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Signal {
    NeedsSafetyAudit,
    NeedsPerfTest,
    NeedsReview,
    NeedsUiReview,
}

impl Signal {
    fn word(self) -> &'static str {
        match self {
            Signal::NeedsSafetyAudit => "needs-safety-audit",
            Signal::NeedsPerfTest => "needs-perf-test",
            Signal::NeedsReview => "needs-review",
            Signal::NeedsUiReview => "needs-ui-review",
        }
    }

    fn agent(self) -> &'static str {
        match self {
            Signal::NeedsSafetyAudit => "reviewer-safety",
            Signal::NeedsPerfTest => "reviewer-perf",
            Signal::NeedsReview => "reviewer-correctness",
            Signal::NeedsUiReview => "reviewer-quality",
        }
    }

    fn parse(word: &str) -> Option<Signal> {
        serde_json::from_value(json!(word)).ok()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Judge {
    Add,
    Drop,
}

/// One judgment of the review: a signal added or dropped, with its reason.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Judgment {
    pub judge: Judge,
    pub signal: Signal,
    pub reason: String,
}

/// The request, tagged by `step`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "step", rename_all = "kebab-case", deny_unknown_fields)]
pub enum RecordQaDecision {
    Scan {
        worktree: PathBuf,
        base: String,
        #[serde(default)]
        judgments: Vec<Judgment>,
    },
    /// The user skipped QA: the routing names no signal.
    Skip {},
}

const SKIP_RATIONALE: &str = "user skip";

fn refuse(key: &'static str, fields: &[(&str, &str)]) -> Error {
    agent_runtime::Error::refused(key, fields).into()
}

/// `git -C worktree args` through the one runner: its exit, or `None` where
/// it gave no exit, and its stdout.
#[allow(
    clippy::disallowed_methods,
    reason = "the QA scan's reads of the round's diff through the one runner; they act on nothing"
)]
fn git(worktree: &Path, operation: &'static str, args: &[&str]) -> (Option<i32>, String) {
    let dir = worktree.display().to_string();
    let mut argv = vec!["-C", dir.as_str()];
    argv.extend_from_slice(args);
    match host::run_tagged_in(
        TAG,
        "git",
        Path::new("git"),
        operation,
        &argv,
        Place::default(),
        READ,
    ) {
        Ok(out) => (out.status.code(), host::stdout_text(&out)),
        Err(_) => (None, String::new()),
    }
}

fn exit_word(code: Option<i32>) -> String {
    code.map_or_else(|| "none".to_owned(), |c| c.to_string())
}

/// A setting's glob against a repository-relative path, as the shell
/// pattern `[[ $path == $pattern || $path == $pattern/* ]]` matched it: `*`
/// crosses `/`, `?` is one character, `[...]` a class, and `**/` also
/// matches no directory.
pub fn glob_matches(glob: &str, path: &str) -> bool {
    let pattern = glob.trim_end_matches('/');
    let tokens = tokens(pattern);
    let path: Vec<char> = path.chars().collect();
    if matches(&tokens, &path) {
        return true;
    }
    let mut under = tokens;
    under.push(Token::Char('/'));
    under.push(Token::Star);
    matches(&under, &path)
}

#[derive(Debug, Clone, PartialEq)]
enum Token {
    Char(char),
    Any,
    Star,
    Class(bool, Vec<(char, char)>),
    /// `**/`: either `*/` or nothing.
    Dirs,
}

fn tokens(pattern: &str) -> Vec<Token> {
    let chars: Vec<char> = pattern.chars().collect();
    let mut out = Vec::new();
    let mut i = 0;
    while i < chars.len() {
        match chars[i] {
            '*' if chars.get(i + 1) == Some(&'*') && chars.get(i + 2) == Some(&'/') => {
                out.push(Token::Dirs);
                i += 3;
            }
            '*' => {
                out.push(Token::Star);
                i += 1;
            }
            '?' => {
                out.push(Token::Any);
                i += 1;
            }
            '[' => match class(&chars, i) {
                Some((token, next)) => {
                    out.push(token);
                    i = next;
                }
                None => {
                    out.push(Token::Char('['));
                    i += 1;
                }
            },
            '\\' if i + 1 < chars.len() => {
                out.push(Token::Char(chars[i + 1]));
                i += 2;
            }
            c => {
                out.push(Token::Char(c));
                i += 1;
            }
        }
    }
    out
}

/// A bracket class from `chars[at]`, and the index after its `]`.
fn class(chars: &[char], at: usize) -> Option<(Token, usize)> {
    let mut i = at + 1;
    let negated = matches!(chars.get(i), Some('!' | '^'));
    if negated {
        i += 1;
    }
    let mut ranges = Vec::new();
    let mut first = true;
    while i < chars.len() {
        let c = chars[i];
        if c == ']' && !first {
            return Some((Token::Class(negated, ranges), i + 1));
        }
        first = false;
        if chars.get(i + 1) == Some(&'-') && chars.get(i + 2).is_some_and(|e| *e != ']') {
            ranges.push((c, chars[i + 2]));
            i += 3;
        } else {
            ranges.push((c, c));
            i += 1;
        }
    }
    None
}

fn matches(tokens: &[Token], text: &[char]) -> bool {
    match tokens.split_first() {
        None => text.is_empty(),
        Some((Token::Star, rest)) => (0..=text.len()).any(|k| matches(rest, &text[k..])),
        Some((Token::Dirs, rest)) => {
            matches(rest, text)
                || (1..=text.len()).any(|k| text[k - 1] == '/' && matches(rest, &text[k..]))
        }
        Some((token, rest)) => match text.split_first() {
            None => false,
            Some((c, more)) => {
                let hit = match token {
                    Token::Char(t) => t == c,
                    Token::Any => true,
                    Token::Class(negated, ranges) => {
                        ranges.iter().any(|(lo, hi)| (lo..=hi).contains(&c)) != *negated
                    }
                    Token::Star | Token::Dirs => unreachable!("matched above"),
                };
                hit && matches(rest, more)
            }
        },
    }
}

/// The signals in the order they were added, and every cause.
#[derive(Default)]
struct Scan {
    signals: Vec<Signal>,
    causes: Vec<String>,
}

impl Scan {
    fn add(&mut self, signal: Signal, cause: String) {
        self.causes.push(cause);
        if !self.signals.contains(&signal) {
            self.signals.push(signal);
        }
    }
}

fn scan(
    settings: &Settings,
    doc: &Map<String, Value>,
    worktree: &Path,
    base: &str,
    judgments: &[Judgment],
) -> Result<Value> {
    let mut judged: Vec<Signal> = Vec::new();
    for j in judgments {
        if j.reason.trim().is_empty() {
            return Err(refuse("judgment-reason", &[("signal", j.signal.word())]));
        }
        if judged.contains(&j.signal) {
            return Err(refuse("judgment-conflict", &[("signal", j.signal.word())]));
        }
        judged.push(j.signal);
    }
    let mut out = Scan::default();
    for label in doc
        .get("qa_labels")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        let word = label.as_str().unwrap_or_default();
        if word.is_empty() {
            continue;
        }
        let signal = Signal::parse(word)
            .ok_or_else(|| refuse("unknown-signal", &[("signal", word), ("source", "dev")]))?;
        out.add(signal, format!("dev {word}"));
    }
    let range = format!("{base}...HEAD");
    let pattern = format!("-G{SAFETY_PATTERN}");
    // Never `--quiet`: with -G it can exit 0 over a range holding a match.
    match git(
        worktree,
        "safety-scan",
        &["diff", "--exit-code", &pattern, &range],
    )
    .0
    {
        Some(0) => {}
        Some(1) => out.add(Signal::NeedsSafetyAudit, "safety-scan match".into()),
        other => out.add(
            Signal::NeedsSafetyAudit,
            format!("safety-scan exit={}", exit_word(other)),
        ),
    }
    let (paths_exit, paths) = git(
        worktree,
        "changed-paths",
        &[
            "-c",
            "core.quotePath=false",
            "diff",
            "--no-renames",
            "--name-only",
            &range,
        ],
    );
    for (key, signal) in [
        ("QA_PERF_PATHS", Signal::NeedsPerfTest),
        ("QA_UI_PATHS", Signal::NeedsUiReview),
    ] {
        let globs: Vec<&str> = settings
            .qa
            .get(key)
            .map(|v| v.split_whitespace().collect())
            .unwrap_or_default();
        if globs.is_empty() {
            continue;
        }
        if paths_exit != Some(0) {
            out.add(
                signal,
                format!("{key} paths-unread exit={}", exit_word(paths_exit)),
            );
            continue;
        }
        let hit = paths.lines().filter(|p| !p.is_empty()).find_map(|path| {
            globs
                .iter()
                .find(|glob| glob_matches(glob, path))
                .map(|glob| format!("{key} path={path} glob={glob}"))
        });
        if let Some(cause) = hit {
            out.add(signal, cause);
        }
    }
    for j in judgments {
        let cause = format!(
            "judgment {}={} reason={}",
            match j.judge {
                Judge::Add => "add",
                Judge::Drop => "drop",
            },
            j.signal.word(),
            j.reason
        );
        match j.judge {
            Judge::Add => out.add(j.signal, cause),
            Judge::Drop => {
                out.signals.retain(|s| *s != j.signal);
                out.causes.push(cause);
            }
        }
    }
    let mut advisory = Vec::new();
    if let Some(missing) = PERF_DECLARATION
        .iter()
        .find(|k| !settings.qa.contains_key(**k))
        && out.signals.contains(&Signal::NeedsPerfTest)
    {
        out.signals.retain(|s| *s != Signal::NeedsPerfTest);
        advisory.push(json!({
            "signal": Signal::NeedsPerfTest.word(),
            "agent": Signal::NeedsPerfTest.agent(),
            "cause": format!("review-unproducible key={missing}"),
        }));
    }
    let rationale = if out.causes.is_empty() {
        "scan: no signal".to_owned()
    } else {
        out.causes.join("; ")
    };
    let mut decision = json!({
        "signals": out.signals.iter().map(|s| s.word()).collect::<Vec<_>>(),
        "agents": out.signals.iter().map(|s| (s.word().to_owned(), json!(s.agent()))).collect::<Map<_, _>>(),
        "rationale": rationale,
    });
    if !advisory.is_empty() {
        decision["advisory"] = json!(advisory);
    }
    Ok(decision)
}

/// Write `f`'s change to the item's `qa_decision` in one transition.
#[allow(
    clippy::disallowed_methods,
    reason = "the QA decision committed under the item's write check"
)]
fn update<T>(
    path: &Path,
    locking: Locking,
    f: impl Fn(&mut Map<String, Value>) -> Result<T>,
) -> Result<T> {
    reread(|| {
        let snapshot = loaded(path)?;
        let mut doc = snapshot.doc.clone();
        let answer = f(&mut doc)?;
        state::store(path, &snapshot, &doc, locking)?;
        Ok(answer)
    })
}

/// Run `r` against the item record at `path`.
pub fn run(
    path: &Path,
    r: &RecordQaDecision,
    settings: &Settings,
    locking: Locking,
) -> Result<Value> {
    match r {
        RecordQaDecision::Scan {
            worktree,
            base,
            judgments,
        } => update(path, locking, |doc| {
            let decision = scan(settings, doc, worktree, base, judgments)?;
            state::set(doc, "qa_decision", decision.clone());
            Ok(decision)
        }),
        RecordQaDecision::Skip {} => update(path, locking, |doc| {
            let decision = json!({"signals": [], "agents": {}, "rationale": SKIP_RATIONALE});
            state::set(doc, "qa_decision", decision.clone());
            Ok(decision)
        }),
    }
}

/// The routing as the record holds it: the review runs the agent of each
/// signal, and a performance signal no declared runner can review stands
/// advisory beside them.
#[derive(Deserialize)]
struct Decision {
    #[serde(rename = "signals")]
    _signals: Vec<Signal>,
    #[serde(rename = "agents")]
    _agents: std::collections::BTreeMap<String, String>,
    #[serde(rename = "rationale")]
    _rationale: String,
    #[serde(default, rename = "advisory")]
    _advisory: Option<Vec<Value>>,
}

/// The check a pointer write of `qa_decision` is held to.
pub(crate) fn check_decision(now: &Value) -> std::result::Result<(), String> {
    serde_json::from_value::<Option<Decision>>(now.clone())
        .map(drop)
        .map_err(|e| e.to_string())
}
