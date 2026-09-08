//! Stable first-line values from installer-owned messages.

#[allow(clippy::expect_used)]
pub fn value<'a>(output: &'a [u8], key: &str) -> Option<&'a str> {
    let prefix = format!("install.sh: {key}=");
    std::str::from_utf8(output)
        .expect("installer output is UTF-8")
        .lines()
        .find_map(|line| line.strip_prefix(&prefix))
}
