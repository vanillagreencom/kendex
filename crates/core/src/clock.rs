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

/// An ISO-8601 UTC timestamp as [`iso_from_unix`] prints it,
/// `YYYY-MM-DDTHH:MM:SSZ` and nothing else, back to seconds since the
/// Unix epoch. `None` for any other shape, a field outside its range, a
/// date the calendar does not hold, or one before the epoch.
pub fn unix_from_iso(text: &str) -> Option<u64> {
    let bytes = text.as_bytes();
    if bytes.len() != 20 || bytes[10] != b'T' || bytes[19] != b'Z' {
        return None;
    }
    if bytes[4] != b'-' || bytes[7] != b'-' || bytes[13] != b':' || bytes[16] != b':' {
        return None;
    }
    let field = |from: usize, to: usize| -> Option<u32> {
        let digits = &bytes[from..to];
        if !digits.iter().all(u8::is_ascii_digit) {
            return None;
        }
        std::str::from_utf8(digits).ok()?.parse().ok()
    };
    unix_from_civil(
        i64::from(field(0, 4)?),
        field(5, 7)?,
        field(8, 10)?,
        field(11, 13)?,
        field(14, 16)?,
        field(17, 19)?,
    )
}

/// A UTC civil date and time back to seconds since the Unix epoch, the
/// fields [`iso_from_unix`] prints. `None` for a field outside its range
/// or a date before the epoch.
fn unix_from_civil(
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
    fn iso_and_unix_round_trip() {
        for secs in [0, 86_399, 951_782_400, 4_107_542_399, 253_402_300_799] {
            let iso = iso_from_unix(secs);
            assert_eq!(unix_from_iso(&iso), Some(secs), "{iso}");
        }
    }

    /// Any other shape, a field outside its range, or a date the calendar
    /// does not hold is refused rather than folded onto a neighbouring
    /// second.
    #[test]
    fn a_stamp_outside_the_shape_or_the_calendar_is_refused() {
        for text in [
            "",
            "2026-09-14T11:26:54",
            "2026-09-14T11:26:54Z ",
            "2026-09-14 11:26:54Z",
            "2026-09-14T11-26-54Z",
            "2026-09-14T11:26:54X",
            "2026-09-1xT11:26:54Z",
            "2026-04-31T00:00:00Z",
            "2026-02-29T00:00:00Z",
            "2026-13-01T00:00:00Z",
            "2026-01-01T24:00:00Z",
            "2026-01-01T00:60:00Z",
            "1969-12-31T23:59:59Z",
        ] {
            assert_eq!(unix_from_iso(text), None, "{text:?}");
        }
    }
}
