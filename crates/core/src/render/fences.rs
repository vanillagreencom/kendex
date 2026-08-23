//! Where the fenced code blocks are, so the prose rewrite leaves them
//! alone.

/// A fence line: any leading whitespace, then three or more backticks or
/// tildes. `bare` — nothing but whitespace after the run — is what makes a
/// line eligible to close a fence rather than open one.
///
/// Indent is not a limit. Markdown allows three spaces at the top level, but
/// a block nested inside a list item starts four in, and that is the common
/// shape in a real skill: a scanner that stops at three reads the block as
/// prose and cuts or rewrites straight through it.
pub fn fence_marker(line: &str) -> Option<(char, usize, bool)> {
    let rest = line.trim_start();
    let marker = rest.chars().next().filter(|c| matches!(c, '`' | '~'))?;
    let run = rest.chars().take_while(|c| *c == marker).count();
    (run >= 3).then(|| (marker, run, rest[run..].trim().is_empty()))
}
