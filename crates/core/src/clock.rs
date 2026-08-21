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

/// Whether this is an instant, and not merely shaped like one.
///
/// `YYYY-MM-DDTHH:MM:SS` with an optional fractional second and an optional
/// offset, range-checked against the calendar — the same shape
/// [`timestamp`] writes. A record arriving from a file somebody else wrote
/// carries a date only if it is a date; "2026-13-45T99:99:99Z" is a string.
pub fn is_instant(value: &str) -> bool {
    let (date, rest) = match value.split_once('T') {
        Some(split) => split,
        None => return false,
    };
    let Some((offset_free, _)) = split_offset(rest) else {
        return false;
    };
    let mut parts = offset_free.splitn(3, ':');
    let (Some(h), Some(m), Some(s), None) =
        (parts.next(), parts.next(), parts.next(), parts.next())
    else {
        return false;
    };
    let seconds = s.split_once('.').map_or(s, |(whole, frac)| {
        match !frac.is_empty() && frac.bytes().all(|b| b.is_ascii_digit()) {
            true => whole,
            false => s,
        }
    });
    let mut ymd = date.splitn(3, '-');
    let (Some(y), Some(mo), Some(d), None) = (ymd.next(), ymd.next(), ymd.next(), ymd.next())
    else {
        return false;
    };
    let Some(year) = fixed(y, 4) else {
        return false;
    };
    let (Some(month), Some(day)) = (fixed(mo, 2), fixed(d, 2)) else {
        return false;
    };
    let (Some(hour), Some(minute), Some(second)) = (fixed(h, 2), fixed(m, 2), fixed(seconds, 2))
    else {
        return false;
    };
    (1..=12).contains(&month)
        && (1..=days_in_month(year, month)).contains(&day)
        && hour <= 23
        && minute <= 59
        // 60 is a leap second, which a clock can legitimately write.
        && second <= 60
}

/// A fixed-width run of digits, as its value.
fn fixed(value: &str, width: usize) -> Option<u32> {
    (value.len() == width && value.bytes().all(|b| b.is_ascii_digit()))
        .then(|| value.parse().ok())
        .flatten()
}

/// The time half with its trailing offset removed, and the offset. `Z`, or
/// `+HH:MM`/`-HH:MM`, or nothing.
fn split_offset(time: &str) -> Option<(&str, &str)> {
    if let Some(stripped) = time.strip_suffix('Z') {
        return Some((stripped, "Z"));
    }
    let at = time.rfind(['+', '-'])?;
    let (head, offset) = time.split_at(at);
    let hhmm = offset.get(1..)?;
    let (h, m) = hhmm.split_once(':')?;
    (fixed(h, 2)? <= 23 && fixed(m, 2)? <= 59).then_some((head, offset))
}

fn days_in_month(year: u32, month: u32) -> u32 {
    match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 => {
            match year.is_multiple_of(4) && (!year.is_multiple_of(100) || year.is_multiple_of(400))
            {
                true => 29,
                false => 28,
            }
        }
        _ => 0,
    }
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
