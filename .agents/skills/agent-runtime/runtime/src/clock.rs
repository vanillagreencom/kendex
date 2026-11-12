//! The one injected clock, and ISO 8601 UTC stamps with second precision,
//! `YYYY-MM-DDTHH:MM:SSZ`: the one form every record this crate writes and
//! every shell workflow stamp carries, computed without a date crate.

use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

/// The one clock every wait and every wall-clock moment reads: a program
/// builds it once and hands it down, so a test supplies the instants it
/// wants and a bound can be waited without real time passing. `Sync`,
/// since a runner's threads share one.
pub trait Clock: Sync {
    fn now(&self) -> Instant;
    /// The wall-clock time, for a moment a record carries (the instant a
    /// window was asked for, which a session file's appearance is read
    /// against; the epoch second a baseline row holds).
    fn wall(&self) -> SystemTime;
    /// Wait `d` on this clock. The system clock sleeps; a fake clock passes
    /// the time it wants.
    fn sleep(&self, d: Duration);
}

#[derive(Debug, Default, Clone, Copy)]
pub struct SystemClock;

/// The system clock's own reads and its sleep, each behind the one injected
/// clock: the allowance sits on each method alone, so a method added to the
/// trait and this impl needs its own registered site.
impl Clock for SystemClock {
    #[allow(
        clippy::disallowed_methods,
        reason = "the system clock's monotonic read, behind the one injected clock"
    )]
    fn now(&self) -> Instant {
        Instant::now()
    }
    #[allow(
        clippy::disallowed_methods,
        reason = "the system clock's wall read, behind the one injected clock"
    )]
    fn wall(&self) -> SystemTime {
        SystemTime::now()
    }
    #[allow(
        clippy::disallowed_methods,
        reason = "the system clock's sleep, behind the one injected clock"
    )]
    fn sleep(&self, d: Duration) {
        std::thread::sleep(d);
    }
}

/// The current time as an ISO 8601 UTC stamp. A clock set before the epoch
/// reads as the epoch.
pub fn now() -> String {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    iso_utc(secs)
}

/// `secs` since the Unix epoch as `YYYY-MM-DDTHH:MM:SSZ`.
pub fn iso_utc(secs: u64) -> String {
    let days = secs / 86_400;
    let rem = secs % 86_400;
    let (y, m, d) = civil_from_days(days as i64);
    format!(
        "{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z",
        rem / 3600,
        (rem % 3600) / 60,
        rem % 60
    )
}

/// The seconds since the Unix epoch a `YYYY-MM-DDTHH:MM:SSZ` stamp names,
/// `None` for any other text. The inverse of [`iso_utc`].
pub fn epoch_secs(stamp: &str) -> Option<u64> {
    let bytes = stamp.as_bytes();
    if bytes.len() != 20
        || bytes[4] != b'-'
        || bytes[7] != b'-'
        || bytes[10] != b'T'
        || bytes[13] != b':'
        || bytes[16] != b':'
        || bytes[19] != b'Z'
    {
        return None;
    }
    let num = |range: std::ops::Range<usize>| -> Option<i64> {
        let text = stamp.get(range)?;
        if !text.bytes().all(|b| b.is_ascii_digit()) {
            return None;
        }
        text.parse().ok()
    };
    let (y, m, d) = (num(0..4)?, num(5..7)?, num(8..10)?);
    let (h, mi, s) = (num(11..13)?, num(14..16)?, num(17..19)?);
    if !(1..=12).contains(&m) || !(1..=31).contains(&d) || h > 23 || mi > 59 || s > 59 {
        return None;
    }
    let days = days_from_civil(y, m, d);
    u64::try_from(days * 86_400 + h * 3600 + mi * 60 + s).ok()
}

fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y.rem_euclid(400);
    let mp = if m > 2 { m - 3 } else { m + 9 };
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Expected values from `date -u -d @<secs> +%FT%TZ`.
    #[test]
    fn iso_utc_renders_the_stamp_form_date_u_prints() {
        let rows = [
            (0, "1970-01-01T00:00:00Z"),
            (1_769_700_000, "2026-01-29T15:20:00Z"),
            (951_782_400, "2000-02-29T00:00:00Z"),
        ];
        for (secs, text) in rows {
            assert_eq!(iso_utc(secs), text);
            assert_eq!(epoch_secs(text), Some(secs));
        }
        for bad in [
            "2026-01-29 15:20:00Z",
            "2026-13-01T00:00:00Z",
            "",
            "2026-01-29T15:20:00",
        ] {
            assert_eq!(epoch_secs(bad), None, "{bad}");
        }
    }
}
