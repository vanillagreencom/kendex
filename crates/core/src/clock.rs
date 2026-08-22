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

/// Whether this is spelled the way [`timestamp`] spells an instant:
/// `YYYY-MM-DDTHH:MM:SS` in fixed-width digits, with an optional fractional
/// second and an optional offset.
///
/// Shape, not calendar. Nothing reads one of these as a date — they are
/// printed and compared for exact equality — so what has to be bounded is
/// the bytes a file somebody else wrote can put on a terminal, not which
/// days a month has.
pub fn looks_like_instant(value: &str) -> bool {
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
    [(y, 4), (mo, 2), (d, 2), (h, 2), (m, 2), (seconds, 2)]
        .into_iter()
        .all(|(part, width)| fixed(part, width).is_some())
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
