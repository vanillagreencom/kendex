//! Wall-clock timestamps without an external time dependency.

/// Now, as seconds since the Unix epoch.
pub fn unix_now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Seconds-since-epoch as an ISO-8601 UTC timestamp.
pub fn iso_from_unix(secs: u64) -> String {
    let days = secs / 86_400;
    let (year, month, day) = civil_from_days(days as i64);
    let rem = secs % 86_400;
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z",
        rem / 3600,
        (rem % 3600) / 60,
        rem % 60
    )
}

/// Now, as an ISO-8601 UTC timestamp.
pub fn timestamp() -> String {
    iso_from_unix(unix_now())
}

/// A UTC civil date and time back to seconds since the Unix epoch: the
/// inverse of [`iso_from_unix`] over the fields it prints. `None` for a
/// field outside its range or a date before the epoch.
pub fn unix_from_civil(
    year: i64,
    month: u32,
    day: u32,
    hour: u32,
    minute: u32,
    second: u32,
) -> Option<u64> {
    if !(1..=12).contains(&month) || !(1..=31).contains(&day) {
        return None;
    }
    if hour > 23 || minute > 59 || second > 59 {
        return None;
    }
    let days = days_from_civil(year, month, day);
    // A day the calendar does not hold (31 April) lands on the next month
    // and reads back as another date, so it is refused rather than folded.
    if civil_from_days(days) != (year, month, day) {
        return None;
    }
    let secs = days * 86_400 + i64::from(hour) * 3600 + i64::from(minute) * 60 + i64::from(second);
    u64::try_from(secs).ok()
}

/// Howard Hinnant's days-from-civil: (y, m, d) → days since 1970-01-01.
fn days_from_civil(year: i64, month: u32, day: u32) -> i64 {
    let year = if month <= 2 { year - 1 } else { year };
    let era = if year >= 0 { year } else { year - 399 } / 400;
    let yoe = year - era * 400;
    let month = i64::from(month);
    let mp = if month > 2 { month - 3 } else { month + 9 };
    let doy = (153 * mp + 2) / 5 + i64::from(day) - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// Howard Hinnant's civil-from-days: days since 1970-01-01 → (y, m, d).
fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let year = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let month = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if month <= 2 { year + 1 } else { year }, month, day)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The two directions agree over the epoch, a leap day, the end of a
    /// century and a far date, so a stamp read back names the second it
    /// was written at.
    #[test]
    fn civil_and_unix_round_trip() {
        for secs in [0, 86_399, 951_782_400, 4_107_542_399, 253_402_300_799] {
            let iso = iso_from_unix(secs);
            let (date, time) = iso.split_once('T').unwrap();
            let mut ymd = date.split('-').map(|part| part.parse::<i64>().unwrap());
            let mut hms = time
                .trim_end_matches('Z')
                .split(':')
                .map(|part| part.parse::<u32>().unwrap());
            let back = unix_from_civil(
                ymd.next().unwrap(),
                ymd.next().unwrap() as u32,
                ymd.next().unwrap() as u32,
                hms.next().unwrap(),
                hms.next().unwrap(),
                hms.next().unwrap(),
            );
            assert_eq!(back, Some(secs), "{iso}");
        }
    }

    /// A field outside its range, or a date the calendar does not hold, is
    /// refused rather than folded onto a neighbouring second.
    #[test]
    fn a_civil_time_outside_the_calendar_is_refused() {
        let rows: [(i64, u32, u32, u32, u32, u32); 6] = [
            (2026, 4, 31, 0, 0, 0),
            (2026, 2, 29, 0, 0, 0),
            (2026, 13, 1, 0, 0, 0),
            (2026, 1, 1, 24, 0, 0),
            (2026, 1, 1, 0, 60, 0),
            (1969, 12, 31, 23, 59, 59),
        ];
        for (y, m, d, h, mi, s) in rows {
            assert_eq!(unix_from_civil(y, m, d, h, mi, s), None, "{y}-{m}-{d}");
        }
    }
}
