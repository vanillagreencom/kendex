//! Anchored family grammar and numeric freshness, shared by every runtime.
use super::{ClassRow, TIERS};
use crate::model::HarnessId;

pub(super) fn selectors_equivalent(harness: HarnessId, prior: &str, current: &str) -> bool {
    if prior == current {
        return true;
    }
    if harness != HarnessId::Claude {
        return false;
    }
    let prior = prior.strip_prefix("anthropic/").unwrap_or(prior);
    let current = current.strip_prefix("anthropic/").unwrap_or(current);
    if prior.contains('/') || current.contains('/') {
        return false;
    }
    prior == current
        || TIERS.iter().any(|row| {
            (row.claude == Some(prior) && matches("anthropic", current, row).is_some())
                || (row.claude == Some(current) && matches("anthropic", prior, row).is_some())
        })
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub(super) struct Release {
    components: Vec<u32>,
    // Undated selectors take priority over snapshots of the same release.
    undated: bool,
    date: u32,
}
fn date(value: &str) -> Option<u32> {
    if value.len() != 8 || !value.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let year: u32 = value[..4].parse().ok()?;
    let month: u32 = value[4..6].parse().ok()?;
    let day: u32 = value[6..].parse().ok()?;
    let days = match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if year.is_multiple_of(400) || (year.is_multiple_of(4) && !year.is_multiple_of(100)) => {
            29
        }
        2 => 28,
        _ => return None,
    };
    (year > 0 && day > 0 && day <= days)
        .then(|| value.parse().ok())
        .flatten()
}
fn release(value: &str) -> Option<Vec<u32>> {
    if value.is_empty() {
        return None;
    }
    let mut parts: Vec<u32> = value
        .split(['.', '-'])
        .map(|part| {
            if part.is_empty() || !part.bytes().all(|b| b.is_ascii_digit()) {
                None
            } else {
                part.parse().ok()
            }
        })
        .collect::<Option<_>>()?;
    while parts.len() > 1 && parts.last() == Some(&0) {
        parts.pop();
    }
    Some(parts)
}
fn claude_release(id: &str, family: &str) -> Option<Release> {
    let rest = id.strip_prefix("claude-")?;
    // Releases before 4 name the version first: `claude-3-5-haiku-20241022`.
    let (version, snapshot) = match rest.strip_prefix(family).and_then(|t| t.strip_prefix('-')) {
        Some(tail) => match tail.rsplit_once('-') {
            Some((version, last)) if last.len() == 8 => (version, Some(date(last)?)),
            _ => (tail, None),
        },
        None => {
            let (version, after) = rest.split_once(&format!("-{family}"))?;
            match after {
                "" => (version, None),
                suffix => (version, Some(date(suffix.strip_prefix('-')?)?)),
            }
        }
    };
    Some(Release {
        components: release(version)?,
        undated: snapshot.is_none(),
        date: snapshot.unwrap_or(0),
    })
}

/// Compatibility substitution has a fixed ceiling; newer exact pins retain their id.
pub(super) fn excluded_haiku(id: &str) -> bool {
    id == "haiku"
        || claude_release(id, "haiku")
            .is_some_and(|release| release.components.as_slice() <= [4, 5].as_slice())
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum Vendor {
    Claude,
    Gpt,
}

pub(super) fn vendor(id: &str) -> Option<Vendor> {
    let id = id.rsplit('/').next()?;
    if id.starts_with("claude-") {
        Some(Vendor::Claude)
    } else if id.starts_with("gpt-") {
        Some(Vendor::Gpt)
    } else {
        None
    }
}

pub(super) fn matches(provider: &str, id: &str, row: &ClassRow) -> Option<Release> {
    let segment = id.rsplit('/').next()?;
    match vendor(segment) {
        Some(Vendor::Claude) => return claude_release(segment, row.claude?),
        Some(Vendor::Gpt) => {}
        None if provider == "anthropic" && row.claude == Some(id) => {
            return Some(Release {
                components: vec![u32::MAX],
                undated: true,
                date: 0,
            });
        }
        None => return None,
    }
    let rest = segment.strip_prefix("gpt-")?;
    let (version, tail) = rest.split_once('-')?;
    let snapshot = if tail == row.gpt {
        None
    } else {
        let suffix = tail.strip_prefix(row.gpt)?.strip_prefix('-')?;
        let compact = suffix.replace('-', "");
        Some(date(&compact)?)
    };
    Some(Release {
        components: release(version)?,
        undated: snapshot.is_none(),
        date: snapshot.unwrap_or(0),
    })
}
