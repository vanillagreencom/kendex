//! The line a run that failed ends on, and which door its text takes.
//!
//! Two doors, because a break means two things. A break inside a value is
//! content: a name off a foreign tree carrying one is a name, and escaping
//! the whole message keeps it on the one line the message wrote. A break a
//! message wrote is structure: a refusal naming one finding per line is
//! read as lines, so that one is split before it is escaped.
//!
//! The error itself is the only thing that knows which it is, so the choice
//! is made here rather than at the call site — [`outro_refusal`] takes the
//! error, not its text.

use super::{Mode, escaped, mode, write_line};

/// A refusal whose line breaks are its own.
///
/// The obligation in [`super`]'s module doc, made a type. A refusal wearing
/// this is split into lines where it prints, so the values inside it are
/// escaped where it was composed; every other error is one line, however
/// hostile the values in it are, and needs no such care.
#[derive(Debug)]
pub struct Lines(pub String);

impl std::fmt::Display for Lines {
    fn fmt(&self, out: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        out.write_str(&self.0)
    }
}

impl std::error::Error for Lines {}

/// The error a run ended on, said as the line that closes it.
pub fn outro_refusal(error: &(dyn std::error::Error + 'static)) {
    closed(&lines("Error: ", error).join("\n"));
}

/// A refusal a run says and then carries on past, under a headline the
/// caller wrote.
///
/// The same choice [`outro_refusal`] makes, for the verb that names a scope
/// it could not check and goes on to the next one. `headline` is the
/// caller's own sentence and is escaped whole like any other: the place it
/// names is a path somebody chose, so a break in it is content.
pub fn fail_refusal(headline: &str, error: &(dyn std::error::Error + 'static)) {
    for line in lines(headline, error) {
        super::drawn_fail(&line);
    }
}

/// The lines a refusal prints on: the headline on the first, then the
/// error's own text, escaped a line at a time where it wrote the breaks and
/// escaped whole where it did not.
///
/// One place, so the two doors cannot drift apart, and no call site is
/// handed the choice: a `&str` door is one a future caller can reach for
/// with a message it composed out of values nobody escaped, which is
/// exactly how `verify` came to forge a line of its own verdict.
fn lines(headline: &str, error: &(dyn std::error::Error + 'static)) -> Vec<String> {
    let text = error.to_string();
    let body: Vec<String> = match owns_its_breaks(error) {
        true => text.split('\n').map(escaped).collect(),
        false => vec![escaped(&text)],
    };
    let headline = escaped(headline);
    body.into_iter()
        .enumerate()
        .map(|(at, line)| match at {
            0 => format!("{headline}{line}"),
            _ => line,
        })
        .collect()
}

/// Whether this error wrote the breaks it holds: core's manifest refusal,
/// which names one finding per line; its TOML refusal, which carries the
/// parser's caret under the source line it points at; and the CLI's own
/// [`Lines`].
///
/// Both core errors escape the path they name where they compose it, and
/// neither escapes the rest — a `Finding` escapes its own three parts, and
/// a `toml::de::Error`'s text is the parser's, written by the one crate
/// every constructor of that variant hands it. Escaping either whole is
/// what took the caret out from under its line.
fn owns_its_breaks(error: &(dyn std::error::Error + 'static)) -> bool {
    use kendex_core::error::CoreError;
    error.is::<Lines>()
        || matches!(
            error.downcast_ref::<CoreError>(),
            Some(CoreError::ManifestInvalid { .. } | CoreError::TomlParse { .. })
        )
}

/// The last line of a run that failed, said as one line whatever a value
/// inside it holds. Plain mode prints what it always printed; a frame
/// closes on it in the failure style.
pub fn outro_fail(text: &str) {
    closed(&escaped(text));
}

fn closed(text: &str) {
    match mode() {
        Mode::Plain => write_line(text),
        Mode::Pretty => super::blocks::fail_frame(text),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    use kendex_core::error::CoreError;

    /// The whole table the door is chosen from. Nothing else may reach the
    /// splitting one: an error carrying a break it did not write is a
    /// sentence with a value in it, and splitting there is how a directory
    /// name writes a second line of the run's account of why it stopped.
    #[test]
    fn only_a_message_that_wrote_its_breaks_takes_the_splitting_door() {
        assert!(owns_its_breaks(&Lines("one\ntwo".to_owned())));
        assert!(owns_its_breaks(&CoreError::ManifestInvalid {
            path: std::path::PathBuf::from("kendex.toml"),
            findings: Vec::new(),
        }));

        // A refusal composed as text, break and all. Nothing about it says
        // the break is the message's rather than a value's.
        let composed: Box<dyn std::error::Error> = "one\ntwo".into();
        assert!(!owns_its_breaks(composed.as_ref()));
        assert!(!owns_its_breaks(&CoreError::NoHomeDir));
        assert!(!owns_its_breaks(&CoreError::NotADirectory {
            path: std::path::PathBuf::from("here"),
        }));
    }
}
