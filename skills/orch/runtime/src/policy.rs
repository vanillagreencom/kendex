//! The consumer's committed policy: the review gate's keys and the optional
//! stages the consumer chose, read from its main checkout's files. A
//! stage runs because the consumer chose it, never because its tool is
//! installed: nothing here probes an installation, and a chosen stage whose
//! tool is absent still answers `run`.
use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

use serde_json::{Map, Value, json};

use crate::error::Result;
use crate::settings;

/// The optional stages the consumer runs, a space-separated list of
/// [`Stage`] words: unset runs every stage, an empty value none.
pub const STAGES_KEY: &str = "ORCH_STAGES";

/// The consumer's committed review policy from the base checkout's files,
/// `kendex.settings.toml`, then `.kendex/settings.toml`, then its private
/// env file where `private_env` holds, the later outranking the earlier; no
/// process variable reaches it, since the policy is the consumer's, never
/// the caller's.
pub fn policy(base: &Path, private_env: bool) -> Result<BTreeMap<String, String>> {
    let mut values = BTreeMap::new();
    for name in agent_runtime::settings::SETTINGS_FILES {
        for (key, value) in agent_runtime::settings::settings_file(&base.join(name))? {
            values.insert(key, value);
        }
    }
    if private_env {
        let private = agent_runtime::settings::private_env_file(
            &base.join(agent_runtime::settings::DEFAULT_ENV_FILE),
            None,
            &settings::KEYS,
        )?;
        values.extend(private.values);
    }
    Ok(values)
}

/// An optional stage a consumer may leave out. Required remote protections,
/// the review gate, required checks and the merge queue, are never one.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Stage {
    ExternalReview,
    LocalReview,
    Preflight,
    DocLimits,
    GitHooks,
    FocusedProof,
}

impl Stage {
    pub const EVERY: [Stage; 6] = [
        Stage::ExternalReview,
        Stage::LocalReview,
        Stage::Preflight,
        Stage::DocLimits,
        Stage::GitHooks,
        Stage::FocusedProof,
    ];

    pub fn word(self) -> &'static str {
        match self {
            Stage::ExternalReview => "external-review",
            Stage::LocalReview => "local-review",
            Stage::Preflight => "preflight",
            Stage::DocLimits => "doc-limits",
            Stage::GitHooks => "git-hooks",
            Stage::FocusedProof => "focused-proof",
        }
    }

    pub fn parse(word: &str) -> Option<Stage> {
        Stage::EVERY.into_iter().find(|stage| stage.word() == word)
    }
}

/// The stages a consumer's policy runs, and whether it names them at all.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Stages {
    set: bool,
    chosen: BTreeSet<Stage>,
}

impl Stages {
    /// The stages `policy` chooses; a word outside [`Stage`] refuses by the
    /// key and the value as written, so a misspelt stage is never skipped.
    pub fn of(policy: &BTreeMap<String, String>) -> Result<Stages> {
        let Some(value) = policy.get(STAGES_KEY) else {
            return Ok(Stages {
                set: false,
                chosen: Stage::EVERY.into_iter().collect(),
            });
        };
        let chosen = value
            .split_whitespace()
            .map(|word| {
                Stage::parse(word)
                    .ok_or_else(|| agent_runtime::settings::value_refusal(STAGES_KEY, value))
            })
            .collect::<std::result::Result<_, _>>()?;
        Ok(Stages { set: true, chosen })
    }

    /// The stages the committed policy of the main checkout `base` runs.
    pub fn read(base: &Path, private_env: bool) -> Result<Stages> {
        Stages::of(&policy(base, private_env)?)
    }

    pub fn runs(&self, stage: Stage) -> bool {
        self.chosen.contains(&stage)
    }
}

fn answer(stages: &Stages, stage: Stage) -> &'static str {
    if stages.runs(stage) { "run" } else { "skip" }
}

/// `validate policy`'s answer for the base checkout `base`: every stage's
/// `run` or `skip`, or the one stage asked. A base that is not a directory
/// refuses, since its absent files would read as the default.
pub fn reply(base: &Path, stage: Option<Stage>, private_env: bool) -> Result<Value> {
    if !std::fs::metadata(base).is_ok_and(|m| m.is_dir()) {
        return Err(agent_runtime::Error::refused(
            "field-invalid",
            &[
                ("field", "base_checkout"),
                ("value", &base.display().to_string()),
            ],
        )
        .into());
    }
    let stages = Stages::read(base, private_env)?;
    let mut reply = json!({"base_checkout": base.display().to_string(), "set": stages.set});
    match stage {
        Some(stage) => {
            reply["stage"] = json!(stage.word());
            reply["answer"] = json!(answer(&stages, stage));
        }
        None => {
            let all: Map<String, Value> = Stage::EVERY
                .into_iter()
                .map(|stage| (stage.word().to_owned(), json!(answer(&stages, stage))))
                .collect();
            reply["stages"] = Value::Object(all);
        }
    }
    Ok(reply)
}
