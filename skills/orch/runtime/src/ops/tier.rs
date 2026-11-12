//! The cycle a work item runs at, and the brief verb that opens it.
//!
//! change-scope's launch arm (`change-scope launch`, beside the configured
//! `harness-only`) owns the classification: the class order, the ceilings,
//! the Expected delta, the path rules, the standard paths and the range.
//! This module owns what orch adds: a body with no Location line refused, the
//! paths judged as the admission's one touched-set function reads them over
//! the body and the brief the launch will be given, the cycle each class
//! opens, and the line a launch brief carries. A class the arm could not
//! measure answers standard with the arm's cause: standard is the widest
//! cycle and grants nothing.

use std::path::{Path, PathBuf};
use std::time::Duration;

use agent_runtime::host;

use super::admission::{self, ScopeRange};

const TAG: &str = "tier";
/// How long one run of the arm may take: a range read and its inventory
/// verdict included.
const READ: Duration = Duration::from_secs(60);

/// A cycle a work item runs at.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Cycle {
    Micro,
    Small,
    Standard,
}

impl Cycle {
    /// The cycle a class word names; a class no cycle runs at names none.
    pub fn parse(word: &str) -> Option<Cycle> {
        match word {
            "micro" => Some(Cycle::Micro),
            "small" => Some(Cycle::Small),
            "standard" => Some(Cycle::Standard),
            _ => None,
        }
    }

    pub fn word(self) -> &'static str {
        match self {
            Cycle::Micro => "micro",
            Cycle::Small => "small",
            Cycle::Standard => "standard",
        }
    }

    /// The orch command the launch brief runs.
    fn brief(self) -> &'static str {
        match self {
            Cycle::Micro => "micro",
            Cycle::Small => "small",
            Cycle::Standard => "start",
        }
    }
}

/// A refusal: its cause word, the fields that name what it acted on, and
/// the exit status the verb ends with (1 for an item to refile, 2 for a
/// usage or environment failure).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Refused {
    pub cause: String,
    pub fields: Vec<(String, String)>,
    pub exit: i32,
    /// The arm's own stderr lines, relayed after the refusal.
    pub notes: Vec<String>,
}

impl Refused {
    fn new(cause: &str, fields: &[(&str, &str)], exit: i32) -> Refused {
        Refused {
            cause: cause.to_owned(),
            fields: fields
                .iter()
                .map(|(k, v)| ((*k).to_owned(), (*v).to_owned()))
                .collect(),
            exit,
            notes: Vec::new(),
        }
    }

    /// The keyed line a reader of the refusal reads.
    pub fn line(&self) -> String {
        let mut line = format!("orch-runtime: tier cause={}", self.cause);
        for (field, value) in &self.fields {
            line.push_str(&format!(" {field}={value}"));
        }
        line
    }
}

/// The arm's answer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Classified {
    pub cycle: Cycle,
    /// The deciding input's cause and its detail.
    pub cause: String,
    pub delta: Option<u64>,
    /// The arm's stderr lines other than its class line.
    pub notes: Vec<String>,
}

/// What the arm is asked over.
#[derive(Debug, Default)]
pub struct ArmInput<'a> {
    pub production: Option<u64>,
    pub body: Option<&'a Path>,
    pub floors: &'a [&'a str],
    pub paths: &'a [String],
    pub range: Option<&'a ScopeRange>,
    pub repo: Option<&'a Path>,
}

/// The arm beside the configured change-scope path reader.
pub fn arm_cli(scope_paths_cli: &Path) -> PathBuf {
    scope_paths_cli
        .parent()
        .map(|dir| dir.join("change-scope"))
        .unwrap_or_else(|| PathBuf::from("change-scope"))
}

/// One run of the arm at `cli` over `input`.
#[allow(
    clippy::disallowed_methods,
    reason = "the cycle's classification through change-scope's launch arm, the one runner"
)]
pub fn classify(cli: &Path, input: &ArmInput) -> Result<Classified, Refused> {
    let cli_text = cli.display().to_string();
    if !cli.is_file() {
        return Err(Refused::new(
            "dependency-absent",
            &[("skill", "change-scope"), ("path", &cli_text)],
            2,
        ));
    }
    let mut args: Vec<String> = vec!["launch".to_owned()];
    let mut flag = |name: &str, value: String| {
        args.push(name.to_owned());
        args.push(value);
    };
    if let Some(n) = input.production {
        flag("--production", n.to_string());
    }
    if let Some(body) = input.body {
        flag("--body", body.display().to_string());
    }
    for floor in input.floors {
        flag("--floor", (*floor).to_owned());
    }
    for path in input.paths {
        flag("--path", path.clone());
    }
    if let Some(range) = input.range {
        flag("--base", range.base.clone());
        flag("--head", range.head.clone());
    }
    if let Some(repo) = input.repo {
        flag("--repo", repo.display().to_string());
    }
    let argv: Vec<&str> = args.iter().map(String::as_str).collect();
    let out = host::run_tagged(TAG, "change-scope", cli, "launch", &argv, READ).map_err(|e| {
        Refused::new(
            "launch-arm-failed",
            &[("path", &cli_text), ("cause", &e.to_string())],
            2,
        )
    })?;
    let stderr = host::stderr_text(&out);
    let class_line = stderr.lines().rev().find_map(|l| l.strip_prefix("class: "));
    let notes: Vec<String> = stderr
        .lines()
        .filter(|l| !l.starts_with("class: ") && !l.is_empty())
        .map(str::to_owned)
        .collect();
    match out.status.code() {
        Some(0) => {}
        Some(2) => return Err(wiring_refusal(&stderr, &cli_text, notes)),
        code => {
            let exit = code.map_or_else(|| "signal".to_owned(), |c| c.to_string());
            let mut refused = Refused::new("launch-arm-failed", &[("exit", &exit)], 2);
            refused.notes = notes;
            return Err(refused);
        }
    }
    let unreadable = |notes: Vec<String>| {
        let mut refused = Refused::new("class-unreadable", &[], 2);
        refused.notes = notes;
        refused
    };
    let stdout = host::stdout_text(&out);
    let named = stdout.trim().strip_prefix("change_class=");
    let Some((class, delta, cause)) = class_line.and_then(parse_class_line) else {
        return Err(unreadable(notes));
    };
    let cycle = match (Cycle::parse(&class), named) {
        (Some(cycle), Some(word)) if word == class => cycle,
        _ => return Err(unreadable(notes)),
    };
    Ok(Classified {
        cycle,
        cause,
        delta,
        notes,
    })
}

/// `class=C measured=M delta=N|- cause=CAUSE[ DETAIL]` as its class, delta
/// and cause.
fn parse_class_line(line: &str) -> Option<(String, Option<u64>, String)> {
    let rest = line.strip_prefix("class=")?;
    let (class, rest) = rest.split_once(" measured=")?;
    let (_, rest) = rest.split_once(" delta=")?;
    let (delta, cause) = rest.split_once(" cause=")?;
    let delta = match delta {
        "-" => None,
        n => Some(n.parse().ok()?),
    };
    Some((class.to_owned(), delta, cause.to_owned()))
}

/// The arm's wiring error as the verb's refusal: an older change-scope that
/// has no launch arm refuses the arm's own word.
fn wiring_refusal(stderr: &str, cli: &str, notes: Vec<String>) -> Refused {
    let fields = stderr
        .lines()
        .find_map(|l| l.strip_prefix("wiring-error: "))
        .unwrap_or("cause=launch-arm-unreadable");
    let mut words = fields.split(' ');
    let cause = words
        .next()
        .and_then(|w| w.strip_prefix("cause="))
        .unwrap_or("launch-arm-unreadable");
    let rest: Vec<(String, String)> = words
        .filter_map(|w| w.split_once('='))
        .map(|(k, v)| (k.to_owned(), v.to_owned()))
        .collect();
    let mut refused = if cause == "unknown-argument"
        && rest.iter().any(|(k, v)| k == "argument" && v == "launch")
    {
        Refused::new("launch-arm-absent", &[("path", cli)], 2)
    } else {
        Refused {
            cause: cause.to_owned(),
            fields: rest,
            exit: 2,
            notes: Vec::new(),
        }
    };
    refused.notes = notes;
    refused
}

/// The verb's flags.
#[derive(Debug, clap::Args)]
#[command(group(
    clap::ArgGroup::new("input")
        .required(true)
        .multiple(true)
        .args(["production", "body", "floor", "base"])
))]
pub struct Args {
    /// The launch estimate of the item's added production lines.
    #[arg(long)]
    production: Option<u64>,
    /// The item's body: its Location lines, which name paths, and its
    /// Expected delta, which floors the estimate.
    #[arg(long)]
    body: Option<PathBuf>,
    /// The brief the launch will be given, where it is written: the paths it
    /// names join the touched set.
    #[arg(long)]
    brief: Option<PathBuf>,
    /// A class the item already holds.
    #[arg(long)]
    floor: Option<String>,
    /// The base of the item's range.
    #[arg(long, requires = "head")]
    base: Option<String>,
    /// The head of the item's range.
    #[arg(long, requires = "base")]
    head: Option<String>,
    /// The judged checkout.
    #[arg(long, default_value = ".")]
    repo: PathBuf,
}

/// The verb run: the line on stdout and the arm's notes on stderr at exit
/// 0, else the keyed refusal and the notes on stderr at the refusal's exit.
pub fn run(scope_paths_cli: &Path, args: &Args) -> i32 {
    use std::io::Write;
    let request = Request {
        production: args.production,
        body: args.body.clone(),
        brief: args.brief.clone(),
        floor: args.floor.clone(),
        range: args
            .base
            .clone()
            .zip(args.head.clone())
            .map(|(base, head)| ScopeRange { base, head }),
        repo: args.repo.clone(),
    };
    let mut err = std::io::stderr().lock();
    match tier(&arm_cli(scope_paths_cli), &request) {
        Ok(answer) => {
            for note in &answer.classified.notes {
                let _ = writeln!(err, "{note}");
            }
            let _ = writeln!(std::io::stdout().lock(), "{}", answer.line());
            0
        }
        Err(refused) => {
            let _ = writeln!(err, "{}", refused.line());
            for note in &refused.notes {
                let _ = writeln!(err, "{note}");
            }
            refused.exit
        }
    }
}

/// What the verb is asked over.
#[derive(Debug, Default)]
pub struct Request {
    pub production: Option<u64>,
    pub body: Option<PathBuf>,
    pub brief: Option<PathBuf>,
    pub floor: Option<String>,
    pub range: Option<ScopeRange>,
    pub repo: PathBuf,
}

/// The verb's answer: the line a launch brief carries.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Answer {
    pub classified: Classified,
    /// The launch estimate as given, before the delta floors it.
    pub estimate: Option<u64>,
    pub paths: usize,
}

impl Answer {
    /// `tier=CLASS brief=VERB cause=CAUSE[ DETAIL] estimate=N|- delta=N|-
    /// paths=N`, which the launch reads from the brief.
    pub fn line(&self) -> String {
        let count = |n: Option<u64>| n.map_or_else(|| "-".to_owned(), |n| n.to_string());
        let c = &self.classified;
        format!(
            "tier={} brief={} cause={} estimate={} delta={} paths={}",
            c.cycle.word(),
            c.cycle.brief(),
            c.cause,
            count(self.estimate),
            count(c.delta),
            self.paths
        )
    }
}

fn read(path: &Path, cause: &str) -> Result<String, Refused> {
    std::fs::read_to_string(path).map_err(|e| {
        Refused::new(
            cause,
            &[
                ("path", &path.display().to_string()),
                ("error", &e.kind().to_string().replace(' ', "-")),
            ],
            2,
        )
    })
}

/// The `tier` verb: a body with no Location line, or one whose Location
/// names no path, goes back to filing for a per-subsystem split; else the
/// arm classifies the estimate, the body, the floor, the range and the
/// touched set the body and the brief name.
pub fn tier(cli: &Path, r: &Request) -> Result<Answer, Refused> {
    let refile = |cause: &str| Refused::new(cause, &[("route", "per-subsystem-split")], 1);
    let body = r
        .body
        .as_deref()
        .map(|path| read(path, "body-unreadable"))
        .transpose()?;
    if let Some(text) = &body
        && !text.split('\n').any(admission::is_location_line)
    {
        return Err(refile("no-location"));
    }
    let brief = r
        .brief
        .as_deref()
        .map(|path| read(path, "brief-unreadable"))
        .transpose()?;
    let touched = admission::touched(body.as_deref(), brief.as_deref(), &[], &[])
        .map_err(|_| refile("location-unread"))?;
    let floors: Vec<&str> = r.floor.as_deref().into_iter().collect();
    let classified = classify(
        cli,
        &ArmInput {
            production: r.production,
            body: r.body.as_deref(),
            floors: &floors,
            paths: &touched,
            range: r.range.as_ref(),
            repo: Some(&r.repo),
        },
    )?;
    Ok(Answer {
        classified,
        estimate: r.production,
        paths: touched.len(),
    })
}

/// Whether a merged change's class is wider than the cycle it launched at,
/// read through the arm over both as floors: the arm answers the wider of
/// them, and a class it refuses as a floor is narrower than every cycle.
/// `None` where the arm could not answer.
pub fn escaped(cli: &Path, cycle: &str, class: &str, repo: &Path) -> Option<bool> {
    let tier = Cycle::parse(cycle)?;
    match classify(
        cli,
        &ArmInput {
            floors: &[cycle, class],
            repo: Some(repo),
            ..ArmInput::default()
        },
    ) {
        Ok(classified) => Some(classified.cycle != tier),
        Err(refused)
            if refused.cause == "invalid-floor"
                && refused
                    .fields
                    .iter()
                    .any(|(k, v)| k == "floor" && v == class) =>
        {
            Some(false)
        }
        Err(_) => None,
    }
}
