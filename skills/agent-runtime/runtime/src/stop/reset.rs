//! The reset clause a usage-limit banner states: what
//! shape it comes in and what instant it names given the moment the banner was
//! first seen. The three tails in order, dated (`resets Sep 6, 4pm`, Codex's
//! `Try again at Sep 6th, 2026 4:30 PM`), weekday (`resets Thursday 4am`) and
//! clock (`resets 9:50am (America/Los_Angeles)`, `resets 21:00`); a duration,
//! a weekday with no clock and a bare number name no instant.

use crate::accounts::{usage::FIVE_HOURS_S, wall::LimitReport};
use jiff::civil::{Date, DateTime};
use jiff::tz::{AmbiguousOffset, TimeZone};
use jiff::{Span, Timestamp};

const MONTHS: [&str; 12] = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
];
const WEEKDAYS: [&str; 7] = [
    "Monday",
    "Tuesday",
    "Wednesday",
    "Thursday",
    "Friday",
    "Saturday",
    "Sunday",
];

/// Which tail matched and the day it carries.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Day {
    /// A month and day, the year where printed.
    Dated {
        month: u8,
        day: u8,
        year: Option<i16>,
    },
    /// A weekday, Monday 1 to Sunday 7.
    Weekday(u8),
    /// A clock alone: today or tomorrow from the sighting.
    Clock,
}

/// The wall a banner names, as the key: the tail, the clock in 24-hour
/// form and the zone named in parentheses, if any.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Key {
    pub day: Day,
    pub hour: u8,
    pub minute: u8,
    pub zone: Option<String>,
}

/// A clock as the `USAGE_RESET_CLOCK` reads it: one or two digits, an
/// optional `:MM`, an optional `:SS`, an optional blank, an optional
/// meridiem. `None` without a clock at all; the minutes and meridiem are
/// checked by the caller.
fn clock(text: &str) -> Option<(u32, Option<u8>, Option<char>, usize)> {
    let bytes = text.as_bytes();
    let digits = bytes
        .iter()
        .take(2)
        .take_while(|b| b.is_ascii_digit())
        .count();
    if digits == 0 {
        return None;
    }
    let hour: u32 = text[..digits].parse().ok()?;
    let mut at = digits;
    let mut minute = None;
    if bytes.get(at) == Some(&b':')
        && bytes.len() >= at + 3
        && bytes[at + 1..at + 3].iter().all(u8::is_ascii_digit)
    {
        minute = text[at + 1..at + 3].parse::<u8>().ok();
        at += 3;
    }
    if minute.is_some()
        && bytes.get(at) == Some(&b':')
        && bytes.len() >= at + 3
        && bytes[at + 1..at + 3].iter().all(u8::is_ascii_digit)
    {
        at += 3;
    }
    let mut meridiem = None;
    let mut probe = at;
    if bytes.get(probe).is_some_and(|b| b.is_ascii_whitespace()) {
        probe += 1;
    }
    if let Some(m) = bytes.get(probe..probe + 2)
        && matches!(m[0], b'a' | b'A' | b'p' | b'P')
        && matches!(m[1], b'm' | b'M')
    {
        meridiem = Some(m[0].to_ascii_lowercase() as char);
        at = probe + 2;
    }
    Some((hour, minute, meridiem, at))
}

/// The text after each lead, `resets` or `Try again at` and its blanks,
/// in the order they stand on the line.
fn after_leads(line: &str) -> Vec<&str> {
    let mut out = Vec::new();
    for lead in ["resets", "Resets", "Try again at", "try again at"] {
        for (at, _) in line.match_indices(lead) {
            let rest = &line[at + lead.len()..];
            let trimmed = rest.trim_start();
            if trimmed.len() < rest.len() {
                out.push((at, trimmed));
            }
        }
    }
    out.sort_by_key(|(at, _)| *at);
    out.into_iter().map(|(_, rest)| rest).collect()
}

fn digits(text: &str, max: usize) -> usize {
    text.bytes()
        .take(max)
        .take_while(u8::is_ascii_digit)
        .count()
}

fn letters(text: &str) -> usize {
    text.bytes().take_while(u8::is_ascii_lowercase).count()
}

/// `Mon[th] D[th], [YYYY[,] ]clock`.
fn dated(rest: &str) -> Option<(Day, u32, Option<u8>, Option<char>)> {
    let b = rest.as_bytes();
    if b.len() < 3 || !b[0].is_ascii_uppercase() || !b[1..3].iter().all(u8::is_ascii_lowercase) {
        return None;
    }
    let name = &rest[..3];
    let mut at = 3 + letters(&rest[3..]);
    let blanks = rest[at..].len() - rest[at..].trim_start().len();
    if blanks == 0 {
        return None;
    }
    at += blanks;
    let d = digits(&rest[at..], 2);
    if d == 0 {
        return None;
    }
    let day: u8 = rest[at..at + d].parse().ok()?;
    at += d + letters(&rest[at + d..]);
    if !rest[at..].starts_with(',') {
        return None;
    }
    at += 1;
    let blanks = rest[at..].len() - rest[at..].trim_start().len();
    if blanks == 0 {
        return None;
    }
    at += blanks;
    let month = MONTHS.iter().position(|m| *m == name)? as u8 + 1;
    // The optional year, taken where a clock follows it.
    if digits(&rest[at..], 4) == 4 && !rest[at + 4..].starts_with(':') {
        let year: i16 = rest[at..at + 4].parse().ok()?;
        let mut after = at + 4;
        if rest[after..].starts_with(',') {
            after += 1;
        }
        let blanks = rest[after..].len() - rest[after..].trim_start().len();
        if blanks > 0
            && let Some((h, m, mer, _)) = clock(&rest[after + blanks..])
        {
            return Some((
                Day::Dated {
                    month,
                    day,
                    year: Some(year),
                },
                h,
                m,
                mer,
            ));
        }
    }
    let (h, m, mer, _) = clock(&rest[at..])?;
    Some((
        Day::Dated {
            month,
            day,
            year: None,
        },
        h,
        m,
        mer,
    ))
}

/// `Weekday clock`.
fn weekday(rest: &str) -> Option<(Day, u32, Option<u8>, Option<char>)> {
    let b = rest.as_bytes();
    if b.first().is_none_or(|c| !c.is_ascii_uppercase()) {
        return None;
    }
    let word_len = 1 + letters(&rest[1..]);
    let word = &rest[..word_len];
    if !word.ends_with("day") {
        return None;
    }
    let blanks = rest[word_len..].len() - rest[word_len..].trim_start().len();
    if blanks == 0 {
        return None;
    }
    let dow = WEEKDAYS.iter().position(|w| *w == word)? as u8 + 1;
    let (h, m, mer, _) = clock(&rest[word_len + blanks..])?;
    Some((Day::Weekday(dow), h, m, mer))
}

/// The zone the line names in parentheses: an IANA name of one or more
/// components.
fn zone_of(line: &str) -> Option<String> {
    for (at, _) in line.match_indices('(') {
        let rest = &line[at + 1..];
        let Some(end) = rest.find(')') else { continue };
        let name = &rest[..end];
        let mut parts = name.split('/');
        let first_ok = parts
            .next()
            .is_some_and(|p| !p.is_empty() && p.bytes().all(|b| b.is_ascii_alphabetic()));
        let rest_ok = parts.all(|p| {
            !p.is_empty()
                && p.bytes()
                    .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'+' | b'-'))
        });
        if first_ok && rest_ok {
            return Some(name.to_owned());
        }
    }
    None
}

/// Whether a line of `text` states a reset clause the grammar matches,
/// keyed or not (`USAGE_RESET_ANY_RE`): a clause [`key`] answers `None`
/// for, a clock with neither minutes nor a meridiem, still names a reset.
pub fn clause(text: &str) -> bool {
    text.lines().any(|line| {
        after_leads(line)
            .iter()
            .any(|r| dated(r).is_some() || weekday(r).is_some() || clock(r).is_some())
    })
}

/// The key of the first line of `text` that states a reset in a shape
/// the grammar reads (`usage_reset_key`), the tails tried dated, then
/// weekday, then clock; `None` for none, or for a clock with neither
/// minutes nor a meridiem.
pub fn key(text: &str) -> Option<Key> {
    for line in text.lines() {
        let rests = after_leads(line);
        let found = rests
            .iter()
            .find_map(|r| dated(r))
            .or_else(|| rests.iter().find_map(|r| weekday(r)))
            .or_else(|| {
                rests
                    .iter()
                    .find_map(|r| clock(r).map(|(h, m, mer, _)| (Day::Clock, h, m, mer)))
            });
        let Some((day, hour, minute, meridiem)) = found else {
            continue;
        };
        if minute.is_none() && meridiem.is_none() {
            return None;
        }
        let hour = match meridiem {
            Some('p') if hour != 12 => hour + 12,
            Some('a') if hour == 12 => 0,
            Some(_) | None => hour,
        };
        let hour = u8::try_from(hour).ok()?;
        return Some(Key {
            day,
            hour,
            minute: minute.unwrap_or(0),
            zone: zone_of(line),
        });
    }
    None
}

/// The reset at the banner's first sighting, bounded by an explicit five-hour report.
pub fn reported_epoch(
    text: &str,
    report: Option<LimitReport>,
    first_seen: u64,
    zone: &dyn Fn(Option<&str>) -> Option<TimeZone>,
) -> Option<u64> {
    let key = key(text)?;
    let at = epoch(&key, first_seen, &zone(key.zone.as_deref())?)?;
    // The printed clock may next occur tomorrow, beyond the named window.
    (report != Some(LimitReport::FiveHour) || at.saturating_sub(first_seen) <= FIVE_HOURS_S)
        .then_some(at)
}

/// The UTC instants a wall clock names on `date` in `zone`, ascending:
/// one, two in a fall-back hour, none in a spring-forward gap
/// (`local_instants`).
fn local_instants(zone: &TimeZone, date: Date, key: &Key) -> Vec<i64> {
    let Ok(dt) = DateTime::new(
        date.year(),
        date.month(),
        date.day(),
        key.hour as i8,
        key.minute as i8,
        0,
        0,
    ) else {
        return Vec::new();
    };
    let ambiguous = zone.to_ambiguous_timestamp(dt);
    match ambiguous.offset() {
        AmbiguousOffset::Unambiguous { .. } => ambiguous
            .unambiguous()
            .map(|t| vec![t.as_second()])
            .unwrap_or_default(),
        AmbiguousOffset::Fold { .. } => {
            let earlier = zone.to_ambiguous_timestamp(dt).earlier();
            let later = zone.to_ambiguous_timestamp(dt).later();
            match (earlier, later) {
                (Ok(e), Ok(l)) => vec![e.as_second(), l.as_second()],
                (Ok(_), Err(_)) | (Err(_), Ok(_)) | (Err(_), Err(_)) => Vec::new(),
            }
        }
        AmbiguousOffset::Gap { .. } => Vec::new(),
    }
}

/// The instant `key` names given the sighting `since` (`usage_reset_epoch`):
/// a dated clause its own day, in the year it printed or the one of
/// three around the sighting nearest it, the later instant in a
/// fall-back hour; a weekday or a clock its first occurrence strictly
/// after the sighting, over both instants a fold names. `None` where
/// the clock names no instant.
pub fn epoch(key: &Key, since: u64, zone: &TimeZone) -> Option<u64> {
    let since_ts = Timestamp::from_second(i64::try_from(since).ok()?).ok()?;
    let seen = since_ts.to_zoned(zone.clone());
    match key.day {
        Day::Dated { month, day, year } => {
            let years: Vec<i16> = match year {
                Some(year) => vec![year],
                None => vec![seen.year() - 1, seen.year(), seen.year() + 1],
            };
            let mut best: Option<(i64, i64)> = None;
            for y in years {
                let Ok(date) = Date::new(y, month as i8, day as i8) else {
                    continue;
                };
                let Some(cand) = local_instants(zone, date, key).last().copied() else {
                    continue;
                };
                let distance = (cand - since as i64).abs();
                if best.is_none_or(|(_, d)| distance < d) {
                    best = Some((cand, distance));
                }
            }
            best.and_then(|(cand, _)| u64::try_from(cand).ok())
        }
        Day::Weekday(_) | Day::Clock => {
            let (dow, last) = match key.day {
                Day::Weekday(dow) => (Some(dow), 7),
                Day::Clock | Day::Dated { .. } => (None, 1),
            };
            for d in 0..=last {
                let Ok(date) = seen.date().checked_add(Span::new().days(d)) else {
                    continue;
                };
                if dow.is_some_and(|dow| date.weekday().to_monday_one_offset() != dow as i8) {
                    continue;
                }
                for cand in local_instants(zone, date, key) {
                    if cand > since as i64 {
                        return u64::try_from(cand).ok();
                    }
                }
            }
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The rows hold the answers on the banners (`RESET_NOW` 1788364800
    /// read in UTC): each form the grammar accepts resolves to the instant
    /// the row pins, and the forms it excludes name none.
    #[test]
    fn the_reset_clause_resolves_to_the_instant_each_banner_names() {
        let since = 1_788_364_800;
        let utc = TimeZone::UTC;
        let la = TimeZone::get("America/Los_Angeles").unwrap();
        let rows: [(&str, &TimeZone, u64, Option<u64>); 15] = [
            (
                "You've hit your usage limit \u{b7} resets 9:50am (America/Los_Angeles)",
                &utc,
                since,
                Some(1_788_367_800),
            ),
            (
                "You've hit your usage limit \u{b7} resets 9:50pm (UTC)",
                &la,
                since,
                Some(1_788_385_800),
            ),
            (
                "You've hit your session limit \u{b7} resets 21:00",
                &utc,
                since,
                Some(1_788_382_800),
            ),
            (
                "You've hit your usage limit \u{b7} resets 12pm",
                &utc,
                since,
                Some(1_788_436_800),
            ),
            (
                "You've hit your weekly limit \u{b7} resets Sep 6, 4pm",
                &utc,
                since,
                Some(1_788_710_400),
            ),
            (
                "You've hit your weekly limit \u{b7} resets Oct 7, 2027, 11:32am",
                &utc,
                since,
                Some(1_822_908_720),
            ),
            (
                "You've hit your weekly limit \u{b7} resets Thursday 4am",
                &utc,
                since,
                Some(1_788_408_000),
            ),
            (
                "You've hit your usage limit. Try again at Sep 6th, 2026 4:30 PM",
                &utc,
                since,
                Some(1_788_712_200),
            ),
            (
                "You've hit your weekly limit \u{b7} resets Aug 30, 4pm",
                &utc,
                since,
                Some(1_788_105_600),
            ),
            (
                "You've hit your weekly limit \u{b7} resets Oct 4, 6pm (UTC)",
                &utc,
                since,
                Some(1_791_136_800),
            ),
            (
                "You've hit your usage limit \u{b7} resets 9:50am (America/Los_Angeles)",
                &utc,
                1_788_369_300,
                Some(1_788_454_200),
            ),
            (
                "You've hit your usage limit \u{b7} resets 17:00",
                &utc,
                1_788_372_000,
                Some(1_788_454_800),
            ),
            (
                "You've hit your fast limit \u{b7} resets in 5m",
                &utc,
                since,
                None,
            ),
            (
                "You've hit your usage limit \u{b7} resets 2026-09-03",
                &utc,
                since,
                None,
            ),
            (
                "You've hit your weekly limit \u{b7} resets Thursday",
                &utc,
                since,
                None,
            ),
        ];
        for (banner, zone, since, want) in rows {
            let got = key(banner).and_then(|k| {
                let zone = match k.zone.as_deref() {
                    Some(name) => TimeZone::get(name).unwrap(),
                    None => (*zone).clone(),
                };
                epoch(&k, since, &zone)
            });
            assert_eq!(got, want, "{banner}");
        }
        let bogus = key("You've hit your usage limit \u{b7} resets 9:50am (Bogus/Zone)").unwrap();
        assert_eq!(bogus.zone.as_deref(), Some("Bogus/Zone"));
        assert!(TimeZone::get("Bogus/Zone").is_err());
    }
}
