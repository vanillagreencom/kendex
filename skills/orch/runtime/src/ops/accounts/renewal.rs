//! The renewal of an expired access token, under the credentials lock every
//! renewer of the account takes: a Claude token by a refresh-token grant at
//! the token endpoint and the credentials file rewritten whole beside
//! itself, a Codex token by the CLI's own `codex app-server` run and its
//! `auth.json` read back. The credentials file is shared with the harness
//! itself and with every other tool on the machine that reads or renews
//! the login, and a refresh-token grant rotates the refresh token, so a
//! renewal that raced another writer would leave the account on a retired
//! token only a fresh login recovers: inside the lock the file is read
//! again and a live token a peer wrote meanwhile is taken as it stands.
//! The refresh token travels on `curl`'s stdin, never on an argument
//! vector, which is world-readable on Linux.

use std::ffi::OsStr;
use std::io::Write;
use std::path::Path;
use std::time::Duration;

use agent_runtime::host::{self, Place};
use agent_runtime::record;
use serde_json::{Value, json};

use super::TAG;
use super::listing::CLAUDE_OAUTH_BETA;
use super::usage::{self, Credential};
use crate::settings::AccountSettings;

/// The token endpoint answers HTTP 429 to a POST carrying no User-Agent,
/// whatever the rate; it matches the `claude-cli/` prefix and reads no
/// version.
const CLAUDE_TOKEN_UA: &str = "claude-cli/2.1.278 (external, cli)";
/// The POST's own bound is curl's `--max-time 25`; the runner's covers the
/// start.
const TOKEN_BOUND: Duration = Duration::from_secs(30);
/// The CLI's run: it keeps running after its stdin closes while a refresh
/// is in flight and its own request timeouts end it.
const CODEX_BOUND: Duration = Duration::from_secs(60);
/// A peer's renewal under the lock is one POST under its own bound.
const LOCK_WAIT: Duration = Duration::from_secs(30);
/// What `codex app-server` reads on stdin for a renewal: the handshake,
/// then `account/read` with `refreshToken`, the request its protocol
/// documents as asking the CLI to refresh its token before answering.
const CODEX_RENEW_REQUESTS: &str = concat!(
    "{\"method\":\"initialize\",\"id\":0,\"params\":{\"clientInfo\":{\"name\":\"orch-runtime\",\"version\":\"1\"}}}\n",
    "{\"method\":\"initialized\"}\n",
    "{\"method\":\"account/read\",\"id\":1,\"params\":{\"refreshToken\":true}}\n",
);

/// Why a renewal did not happen: the status the lane reads, the HTTP code
/// and Retry-After where an endpoint answered, and the cause.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Refused {
    pub status: String,
    pub code: Option<u16>,
    pub retry_after: Option<String>,
    pub cause: String,
}

impl Refused {
    /// A refusal this machine raised on its own, which no endpoint answered.
    fn own(status: &str, cause: String) -> Refused {
        Refused {
            status: status.to_owned(),
            code: None,
            retry_after: None,
            cause,
        }
    }
}

/// The live access token of the `harness` account at `dir`, whose stored
/// token has expired: the one a peer wrote under the lock, else the one
/// this renewal brought back. A held lock leaves the login untested.
#[allow(
    clippy::disallowed_methods,
    reason = "the credentials lock every renewer of an account takes, through agent-runtime's record lock so a peer's flock on the same file excludes it; the one wait is the lock's"
)]
pub fn renew(
    accounts: &AccountSettings,
    harness: &str,
    dir: &str,
    now: u64,
) -> Result<String, Refused> {
    let lock = Path::new(dir).join(".lanes-refresh");
    let lock_file = record::lock_path(&lock);
    let mut guard = record::lock(&lock).map_err(|_| {
        Refused::own(
            "error",
            format!("the lock file {} could not be opened", lock_file.display()),
        )
    })?;
    let wait = record::Wait {
        limit: LOCK_WAIT,
        poll: Duration::from_millis(100),
        timer: &record::SystemTimer,
    };
    let held = guard.with_wait(&wait.start(), || {
        Ok(match usage::credential(harness, dir) {
            Credential::Token {
                token, expires_ms, ..
            } if !usage::expired(expires_ms, now) => Ok(token),
            Credential::Token { .. }
            | Credential::Missing(_)
            | Credential::Invalid(_)
            | Credential::NoToken { .. } => match harness {
                "claude" => claude(accounts, dir, now),
                _ => codex(dir, now),
            },
        })
    });
    held.unwrap_or_else(|_| {
        Err(Refused::own(
            "unreachable",
            format!(
                "another tool holds the credentials lock {}",
                lock_file.display()
            ),
        ))
    })
}

/// A refresh-token grant at the Claude token endpoint, the new token, the
/// rotated refresh token (or the one held where the answer carried none)
/// and the new expiry written back whole. Only a login the endpoint proved
/// dead reads `expired`: a step this machine failed on its own is `error`,
/// a POST that never reached the endpoint `unreachable`. The expiry is
/// written with the token or nothing is: a live token under a past
/// `expiresAt` would renew again on every listing and rotate the refresh
/// token the harness holds; a zero lifetime would do the same.
#[allow(
    clippy::disallowed_methods,
    reason = "the one refresh-token grant at the Claude token endpoint, `curl` as PATH finds it, through the one runner under its tag, the refresh token on its stdin"
)]
fn claude(accounts: &AccountSettings, dir: &str, now: u64) -> Result<String, Refused> {
    let client_id = accounts
        .claude_client_id
        .as_deref()
        .filter(|id| !id.is_empty())
        .ok_or_else(|| {
            Refused::own(
                "error",
                "no OAuth client id is configured (ORCH_LANES_CLAUDE_CLIENT_ID)".to_owned(),
            )
        })?;
    let path = usage::credential_path("claude", dir);
    let mut file = read_json(&path);
    let refresh = file
        .pointer("/claudeAiOauth/refreshToken")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_owned();
    if refresh.is_empty() {
        return Err(Refused::own(
            "expired",
            format!("there is no refresh token in {path} to renew with"),
        ));
    }
    let body = json!({
        "grant_type": "refresh_token",
        "client_id": client_id,
        "refresh_token": refresh,
    })
    .to_string();
    let beta = format!("anthropic-beta: {CLAUDE_OAUTH_BETA}");
    let args = [
        "-s",
        "--max-time",
        "25",
        "-X",
        "POST",
        accounts.claude_token_url.as_str(),
        "-A",
        CLAUDE_TOKEN_UA,
        "-H",
        "Content-Type: application/json",
        "-H",
        &beta,
        "-D",
        "-",
        "-w",
        "\n%{http_code}",
        "--data-binary",
        "@-",
    ];
    let out = host::run_tagged_fed_own_group(
        TAG,
        "curl",
        Path::new("curl"),
        "token",
        &args,
        Place::default(),
        body.as_bytes(),
        TOKEN_BOUND,
    );
    let out = match out {
        Ok(out) if out.status.success() => out,
        Ok(_) | Err(_) => {
            return Err(Refused::own(
                "unreachable",
                "the token endpoint could not be reached".to_owned(),
            ));
        }
    };
    let answer = usage::answer(&String::from_utf8_lossy(&out.stdout));
    let reply: Value = serde_json::from_str(&answer.body).unwrap_or(Value::Null);
    let suffix = error_suffix(&reply);
    let refused = |status: String, cause: String| Refused {
        status,
        code: answer.code,
        retry_after: answer.retry_after.clone(),
        cause,
    };
    if let Some(code) = answer.code.filter(|c| !(200..300).contains(c)) {
        return Err(refused(
            usage::refusal_status(code, "expired"),
            format!("the token endpoint refused the renewal with HTTP {code}{suffix}"),
        ));
    }
    let token = reply
        .get("access_token")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_owned();
    if token.is_empty() {
        return Err(refused(
            "expired".to_owned(),
            format!("the token endpoint returned no access token{suffix}"),
        ));
    }
    let expires_in = reply
        .get("expires_in")
        .and_then(Value::as_u64)
        .filter(|s| *s > 0)
        .ok_or_else(|| {
            refused(
                "expired".to_owned(),
                "the token endpoint returned no usable expires_in".to_owned(),
            )
        })?;
    let rotated = reply
        .get("refresh_token")
        .and_then(Value::as_str)
        .filter(|r| !r.is_empty())
        .unwrap_or(&refresh)
        .to_owned();
    let oauth = &mut file["claudeAiOauth"];
    oauth["accessToken"] = json!(token);
    oauth["refreshToken"] = json!(rotated);
    oauth["expiresAt"] = json!((now + expires_in) * 1000);
    write_whole(Path::new(&path), &file).map_err(|cause| Refused::own("error", cause))?;
    Ok(token)
}

/// The endpoint's own error object as a suffix for the cause, so an
/// operator reads what the endpoint said rather than only that it said no.
fn error_suffix(reply: &Value) -> String {
    let field = |name: &str| {
        reply
            .pointer(&format!("/error/{name}"))
            .and_then(Value::as_str)
            .unwrap_or("")
    };
    match (field("type"), field("message")) {
        ("", "") => String::new(),
        (one, "") | ("", one) => format!(" ({one})"),
        (kind, message) => format!(" ({kind}: {message})"),
    }
}

fn read_json(path: &str) -> Value {
    std::fs::read_to_string(path)
        .ok()
        .and_then(|text| serde_json::from_str(&text).ok())
        .unwrap_or(Value::Null)
}

/// `value` written to a fresh file beside `path`, created exclusively and
/// readable by its owner alone, then renamed over `path`: a reader never
/// parses half a file, and a renewal interrupted before the rename leaves
/// the file as it was.
#[allow(
    clippy::disallowed_methods,
    reason = "the one write of a harness's own credentials file, beside itself and renamed into place, under the credentials lock"
)]
fn write_whole(path: &Path, value: &Value) -> Result<(), String> {
    use std::os::unix::fs::OpenOptionsExt;
    let dir = path.parent().unwrap_or_else(|| Path::new("."));
    let temp = dir.join(format!(".credentials.{}.tmp", std::process::id()));
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&temp)
        .map_err(|e| {
            format!(
                "no temporary file could be created in {}: {e}",
                dir.display()
            )
        })?;
    let text = serde_json::to_string_pretty(value).map_err(|e| e.to_string())? + "\n";
    let written = file
        .write_all(text.as_bytes())
        .and_then(|()| file.sync_all());
    drop(file);
    if let Err(e) = written.and_then(|()| std::fs::rename(&temp, path)) {
        let _ = std::fs::remove_file(&temp);
        return Err(format!(
            "the renewed credentials could not be written to {}: {e}",
            path.display()
        ));
    }
    Ok(())
}

/// The Codex renewal is the CLI's own: a second refresher of one
/// `auth.json` races every Codex session on the account, and the loser
/// holds a revoked login. `codex app-server` in the config dir is asked
/// `account/read` with `refreshToken` and writes `auth.json` as any Codex
/// run does; its answer does not say whether the refresh worked, so the
/// file read back is the verdict.
#[allow(
    clippy::disallowed_methods,
    reason = "the one run of the Codex CLI's own renewal, `codex app-server` in the account's config dir through the one runner under its tag, the requests on its stdin; the CLI writes auth.json and this reads it back"
)]
fn codex(dir: &str, now: u64) -> Result<String, Refused> {
    let path = usage::credential_path("codex", dir);
    let refresh = read_json(&path)
        .pointer("/tokens/refresh_token")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_owned();
    if refresh.is_empty() {
        return Err(Refused::own(
            "expired",
            format!(
                "there is no refresh token in {path} to renew with; log in again with CODEX_HOME={dir} codex login"
            ),
        ));
    }
    if !on_path("codex") {
        return Err(Refused::own(
            "expired",
            format!(
                "no codex command is on PATH to renew it; install the Codex CLI and run codex once with CODEX_HOME={dir}"
            ),
        ));
    }
    let home = [("CODEX_HOME", OsStr::new(dir))];
    let out = host::run_tagged_fed_own_group(
        TAG,
        "codex",
        Path::new("codex"),
        "renew",
        &["app-server"],
        Place {
            cwd: Some(Path::new(dir)),
            env: &home,
        },
        CODEX_RENEW_REQUESTS.as_bytes(),
        CODEX_BOUND,
    );
    let (said, answer) = match &out {
        Ok(out) => (
            last_failure(&String::from_utf8_lossy(&out.stderr)),
            error_answer(&String::from_utf8_lossy(&out.stdout)),
        ),
        Err(_) => (String::new(), String::new()),
    };
    match usage::credential("codex", dir) {
        Credential::Token {
            token, expires_ms, ..
        } if !usage::expired(expires_ms, now) => Ok(token),
        Credential::Token { .. } => Err(codex_refusal(dir, &said, &answer)),
        Credential::Missing(_) | Credential::Invalid(_) | Credential::NoToken { .. } => {
            Err(Refused::own(
                "expired",
                format!(
                    "codex left no access token in {path}; run codex once with CODEX_HOME={dir}"
                ),
            ))
        }
    }
}

/// Why a `codex app-server` run left the token expired: one table over the
/// last `Failed to refresh token:` line the CLI logged and its answer to
/// request 1, each pattern a codex-cli 0.159.0 message. Only a refresh
/// token the endpoint refused is a dead login; a request that never
/// reached the endpoint, or an error answer, leaves it untested.
fn codex_refusal(dir: &str, said: &str, answer: &str) -> Refused {
    if said.contains("Your access token could not be refreshed") {
        return Refused::own(
            "expired",
            format!(
                "codex could not renew it: {said}; log in again with CODEX_HOME={dir} codex login"
            ),
        );
    }
    if said.contains("error sending request for url (https://auth.openai.com/") {
        return Refused::own(
            "unreachable",
            format!("codex could not reach the token endpoint: {said}"),
        );
    }
    let said = if said.is_empty() {
        String::new()
    } else {
        format!("codex could not renew it: {said}; ")
    };
    if !answer.is_empty() {
        return Refused::own(
            "unreachable",
            format!("{said}codex answered the renewal with an error: {answer}"),
        );
    }
    let said = if said.is_empty() {
        "codex did not renew it; ".to_owned()
    } else {
        said
    };
    Refused::own(
        "expired",
        format!("{said}run codex once with CODEX_HOME={dir}"),
    )
}

/// The text after the last `Failed to refresh token: ` the CLI logged.
fn last_failure(stderr: &str) -> String {
    stderr
        .lines()
        .filter_map(|line| line.rsplit_once("Failed to refresh token: "))
        .map(|(_, rest)| rest.to_owned())
        .next_back()
        .unwrap_or_default()
}

/// The CLI's error answers to request 1, one line each: the error's
/// message, or the whole error where it carries none.
fn error_answer(stdout: &str) -> String {
    stdout
        .lines()
        .filter_map(|line| serde_json::from_str::<Value>(line).ok())
        .filter(|reply| {
            reply.get("id").and_then(Value::as_f64) == Some(1.0)
                && reply.get("error").is_some_and(|e| !e.is_null())
        })
        .map(
            |reply| match reply["error"].get("message").and_then(Value::as_str) {
                Some(message) => message.to_owned(),
                None => reply["error"].to_string(),
            },
        )
        .collect::<Vec<String>>()
        .join("\n")
}

/// Whether `program` is an executable file on this process's `PATH`, the
/// path the runner resolves it on.
fn on_path(program: &str) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::env::var_os("PATH").is_some_and(|path| {
        std::env::split_paths(&path).any(|dir| {
            std::fs::metadata(dir.join(program))
                .is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
        })
    })
}
