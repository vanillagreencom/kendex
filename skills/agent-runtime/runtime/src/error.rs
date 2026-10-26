//! Error categories. Every failure names the operation that failed and the
//! identity it failed on; a caller routes on the variant, never on the text.

use std::path::PathBuf;

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("{operation} on {path}: {source}")]
    Io {
        operation: &'static str,
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },
    #[error("{path}: not valid JSON: {source}")]
    Json {
        path: PathBuf,
        #[source]
        source: serde_json::Error,
    },
    /// The record carries a `record_version` this build does not read.
    #[error("{path}: record version {found} is not one of {supported:?}")]
    RecordVersion {
        path: PathBuf,
        found: u64,
        supported: &'static [u64],
    },
    /// A write was asked against a revision the file has moved past.
    #[error("{path}: revision {expected} expected, {found} found")]
    RevisionMismatch {
        path: PathBuf,
        expected: u64,
        found: u64,
    },
    #[error("{path}: {reason}")]
    RecordShape { path: PathBuf, reason: String },
    /// A process operation could not be performed or could not be judged.
    #[error("process {operation} pid={pid}: {cause}")]
    Process {
        operation: &'static str,
        pid: u32,
        cause: String,
    },
    /// An external program this crate drives did not answer as expected.
    #[error("{program} {operation}: {cause}")]
    External {
        program: &'static str,
        operation: &'static str,
        cause: String,
    },
    /// The requested operation is outside what the named harness or host
    /// supports; the cause names the missing native capability.
    #[error("{operation} unsupported on {subject}: {cause}")]
    Unsupported {
        operation: &'static str,
        subject: String,
        cause: String,
    },
    /// A request refused before any effect. `key` is the stable diagnostic
    /// key and `fields` the values it acted on.
    #[error("refused {key}: {fields:?}")]
    Refused {
        key: &'static str,
        fields: Vec<(String, String)>,
    },
}

impl Error {
    pub fn io(operation: &'static str, path: impl Into<PathBuf>, source: std::io::Error) -> Self {
        Error::Io {
            operation,
            path: path.into(),
            source,
        }
    }

    pub fn refused(key: &'static str, fields: &[(&str, &str)]) -> Self {
        Error::Refused {
            key,
            fields: fields
                .iter()
                .map(|(k, v)| ((*k).to_owned(), (*v).to_owned()))
                .collect(),
        }
    }

    /// The stable key a diagnostic line opens with.
    pub fn key(&self) -> &'static str {
        match self {
            Error::Io { .. } => "io-failed",
            Error::Json { .. } => "json-invalid",
            Error::RecordVersion { .. } => "record-version",
            Error::RevisionMismatch { .. } => "revision-mismatch",
            Error::RecordShape { .. } => "record-shape",
            Error::Process { .. } => "process-failed",
            Error::External { .. } => "external-failed",
            Error::Unsupported { .. } => "unsupported",
            Error::Refused { key, .. } => key,
        }
    }
}

pub type Result<T> = std::result::Result<T, Error>;
