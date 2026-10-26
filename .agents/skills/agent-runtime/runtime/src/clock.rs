//! ISO 8601 UTC stamps with second precision, `YYYY-MM-DDTHH:MM:SSZ`: the
//! one form every record this crate writes and every legacy workflow stamp
//! carries, computed without a date crate.

use std::time::{SystemTime, UNIX_EPOCH};

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
        }
    }
}
