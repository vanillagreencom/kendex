//! The kendex.ai community directory and the skills.sh search surface,
//! read the way the app reads any remote: strictly parsed, capped, cached
//! with an ETag, and honest about staleness when the network is away.

pub mod cache;
pub mod client;
pub mod collections;
pub mod credentials;
mod generation;
pub mod index;
pub mod login;
pub mod me;
pub mod skillssh;
pub mod submit;
pub mod view;

use crate::error::{CoreError, Result};
use crate::process::Hardened;
use std::time::Duration;

/// The most a registry response — headers included — may occupy. The
/// site's own caps keep a real index far under this; only a hostile or
/// broken endpoint approaches it, and it is cut off rather than held.
pub const MAX_RESPONSE_BYTES: usize = 20_000_000;

/// Where the directory lives. One environment variable moves every read
/// (previews, tests); nothing else configures it.
pub fn base_url() -> String {
    std::env::var("KENDEX_API").unwrap_or_else(|_| "https://kendex.ai".into())
}

pub struct FetchResponse {
    pub status: u16,
    pub etag: Option<String>,
    pub body: Vec<u8>,
}

/// The one seam registry reads go through — tests hand in a canned
/// transport, production hands in curl.
pub trait Fetch {
    fn get(&self, url: &str, if_none_match: Option<&str>) -> Result<FetchResponse> {
        self.get_auth(url, if_none_match, None)
    }

    /// GET with an optional bearer credential. The credential rides in a
    /// 0600 config file, never in argv.
    fn get_auth(
        &self,
        url: &str,
        if_none_match: Option<&str>,
        bearer: Option<&str>,
    ) -> Result<FetchResponse>;

    fn post_json(&self, url: &str, body: &str) -> Result<FetchResponse> {
        self.post_json_auth(url, body, None)
    }

    /// POST a JSON body, optionally bearer-authenticated. Secrets ride in
    /// the body or the header and both ride in a 0600 config file, so
    /// neither ever shows in a process list.
    fn post_json_auth(&self, url: &str, body: &str, bearer: Option<&str>) -> Result<FetchResponse>;
}

/// curl under the hardened runner: TLS and proxy configuration come from
/// the system, arguments stay data. Plain http is honored only when the
/// caller's URL asks for it explicitly (a local override), never chosen.
pub struct CurlFetch;

/// Release-feed transport. GitHub's stable latest-download URL redirects to
/// an asset URL, so this follows at most three redirects and accepts only
/// HTTPS after the first request.
pub struct ReleaseFeedFetch;

#[derive(Clone, Copy)]
enum Redirects {
    None,
    Https,
}

impl Fetch for CurlFetch {
    fn get_auth(
        &self,
        url: &str,
        if_none_match: Option<&str>,
        bearer: Option<&str>,
    ) -> Result<FetchResponse> {
        // A bearer credential in argv would sit in the process list, so an
        // authenticated read goes through the config-file path instead.
        if let Some(bearer) = bearer {
            let mut config = format!(
                "url = {}\nheader = {}\n",
                curl_quote(url),
                curl_quote(&format!("Authorization: Bearer {bearer}")),
            );
            if let Some(etag) = if_none_match {
                config.push_str(&format!(
                    "header = {}\n",
                    curl_quote(&format!("If-None-Match: {etag}"))
                ));
            }
            return run_with_config(url, &config);
        }
        run_get(url, if_none_match, Redirects::None)
    }

    fn post_json_auth(&self, url: &str, body: &str, bearer: Option<&str>) -> Result<FetchResponse> {
        // Everything sensitive goes through a curl config file readable
        // only by us: a device code, token or bearer header in argv would
        // sit in the process list for anyone on the machine to read.
        let mut config = format!(
            "url = {}\nrequest = \"POST\"\nheader = \"Content-Type: application/json\"\ndata = {}\n",
            curl_quote(url),
            curl_quote(body)
        );
        if let Some(bearer) = bearer {
            config.push_str(&format!(
                "header = {}\n",
                curl_quote(&format!("Authorization: Bearer {bearer}"))
            ));
        }
        run_with_config(url, &config)
    }
}

impl Fetch for ReleaseFeedFetch {
    fn get_auth(
        &self,
        url: &str,
        if_none_match: Option<&str>,
        bearer: Option<&str>,
    ) -> Result<FetchResponse> {
        if bearer.is_some() {
            return Err(CoreError::RegistryUnavailable {
                why: "the release feed never accepts credentials".to_owned(),
            });
        }
        if url.starts_with("file://") {
            return run_file(url);
        }
        run_get_args(Self::request_args(url, if_none_match))
    }

    fn post_json_auth(
        &self,
        _url: &str,
        _body: &str,
        _bearer: Option<&str>,
    ) -> Result<FetchResponse> {
        Err(CoreError::RegistryUnavailable {
            why: "the release feed is read-only".to_owned(),
        })
    }
}

fn run_file(url: &str) -> Result<FetchResponse> {
    let output = Hardened::curl(&[
        "-sS",
        "--proto",
        "=file",
        "--max-filesize",
        "16000000",
        "--",
        url,
    ])
    .timeout(Duration::from_secs(25))
    .max_output(MAX_RESPONSE_BYTES)
    .run()?;
    if !output.status.success() {
        return Err(CoreError::RegistryUnavailable {
            why: String::from_utf8_lossy(&output.stderr).trim().to_string(),
        });
    }
    Ok(FetchResponse {
        status: 200,
        etag: None,
        body: output.stdout,
    })
}

impl ReleaseFeedFetch {
    fn request_args(url: &str, if_none_match: Option<&str>) -> Vec<String> {
        get_args(url, if_none_match, Redirects::Https)
    }
}

fn run_get(url: &str, if_none_match: Option<&str>, redirects: Redirects) -> Result<FetchResponse> {
    run_get_args(get_args(url, if_none_match, redirects))
}

fn run_get_args(args: Vec<String>) -> Result<FetchResponse> {
    let arg_refs: Vec<&str> = args.iter().map(String::as_str).collect();
    // --max-filesize only bounds a body whose length the server declares;
    // the process-level cap holds headers and chunked bodies too.
    let output = Hardened::curl(&arg_refs)
        .timeout(Duration::from_secs(25))
        .max_output(MAX_RESPONSE_BYTES)
        .run()?;
    if !output.status.success() {
        return Err(CoreError::RegistryUnavailable {
            why: String::from_utf8_lossy(&output.stderr).trim().to_string(),
        });
    }
    parse_http_response(&output.stdout)
}

fn get_args(url: &str, if_none_match: Option<&str>, redirects: Redirects) -> Vec<String> {
    let proto = match (url.starts_with("http://"), redirects) {
        (true, Redirects::None) => "=http",
        (true, Redirects::Https) => "=http,https",
        (false, _) => "=https",
    };
    let mut args = vec![
        "-sS".into(),
        "-i".into(),
        "--max-time".into(),
        "20".into(),
        "--proto".into(),
        proto.into(),
        "--max-filesize".into(),
        "16000000".into(),
    ];
    if matches!(redirects, Redirects::Https) {
        args.extend([
            "--location".into(),
            "--max-redirs".into(),
            "3".into(),
            "--proto-redir".into(),
            "=https".into(),
        ]);
    }
    if let Some(etag) = if_none_match {
        args.push("-H".into());
        args.push(format!("If-None-Match: {etag}"));
    }
    args.push("--".into());
    args.push(url.into());
    args
}

/// One curl run whose request details live in a 0600 config file.
fn run_with_config(url: &str, config: &str) -> Result<FetchResponse> {
    let proto = if url.starts_with("http://") {
        "=http"
    } else {
        "=https"
    };
    // The config file carries the request, so a machine that cannot write
    // it never sends one. That is the same fact the runner reports when it
    // cannot spawn curl, and it is said the same way: a caller weighing a
    // cached answer must not read either as the directory going quiet.
    let file = tempfile_0600(config).map_err(|error| CoreError::not_started("curl", error))?;
    let path = file.path().to_string_lossy().into_owned();
    let args = [
        "-sS",
        "-i",
        "--max-time",
        "20",
        "--proto",
        proto,
        "--config",
        &path,
    ];
    let output = Hardened::curl(&args)
        .timeout(Duration::from_secs(25))
        .max_output(MAX_RESPONSE_BYTES)
        .run()?;
    if !output.status.success() {
        return Err(CoreError::RegistryUnavailable {
            why: String::from_utf8_lossy(&output.stderr).trim().to_string(),
        });
    }
    parse_http_response(&output.stdout)
}

/// curl config-file quoting: backslash and double-quote escaped, the
/// value wrapped in quotes so JSON bodies pass through byte-for-byte.
fn curl_quote(value: &str) -> String {
    let mut quoted = String::with_capacity(value.len() + 2);
    quoted.push('"');
    for ch in value.chars() {
        match ch {
            '"' => quoted.push_str("\\\""),
            '\\' => quoted.push_str("\\\\"),
            '\n' => quoted.push_str("\\n"),
            // A bare carriage return would end the config line, letting a
            // header value smuggle a second header — escape it too, even
            // though every value we send today is control-char-free.
            '\r' => quoted.push_str("\\r"),
            _ => quoted.push(ch),
        }
    }
    quoted.push('"');
    quoted
}

fn tempfile_0600(contents: &str) -> Result<tempfile::NamedTempFile> {
    use std::io::Write as _;
    let mut file = tempfile::Builder::new()
        .prefix("kendex-req-")
        .tempfile()
        .map_err(|error| CoreError::io("curl config", error))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        let permissions = std::fs::Permissions::from_mode(0o600);
        std::fs::set_permissions(file.path(), permissions)
            .map_err(|error| CoreError::io(file.path(), error))?;
    }
    file.write_all(contents.as_bytes())
        .map_err(|error| CoreError::io("curl config", error))?;
    file.flush()
        .map_err(|error| CoreError::io("curl config", error))?;
    Ok(file)
}

/// Split `curl -i` output into the final status, ETag and body. Redirects
/// stack header blocks, so blocks are consumed while the remainder still
/// opens like a response.
fn parse_http_response(raw: &[u8]) -> Result<FetchResponse> {
    let mut rest = raw;
    let mut status = 0u16;
    let mut etag = None;
    while rest.starts_with(b"HTTP/") {
        let Some(end) = find_blank_line(rest) else {
            break;
        };
        let head = String::from_utf8_lossy(&rest[..end]);
        let mut lines = head.lines();
        if let Some(code) = lines
            .next()
            .and_then(|line| line.split_whitespace().nth(1))
            .and_then(|code| code.parse::<u16>().ok())
        {
            status = code;
        }
        etag = lines
            .filter_map(|line| line.split_once(':'))
            .find(|(name, _)| name.eq_ignore_ascii_case("etag"))
            .map(|(_, value)| value.trim().to_string());
        rest = &rest[end..];
        while rest.starts_with(b"\r\n") || rest.starts_with(b"\n") {
            rest = if rest.starts_with(b"\r\n") {
                &rest[2..]
            } else {
                &rest[1..]
            };
        }
        // 100-continue and redirect bodies are empty; the next block, if
        // any, opens immediately with its own status line.
    }
    if status == 0 {
        return Err(CoreError::RegistryMalformed {
            why: "response carried no HTTP status line".into(),
        });
    }
    Ok(FetchResponse {
        status,
        etag,
        body: rest.to_vec(),
    })
}

fn find_blank_line(raw: &[u8]) -> Option<usize> {
    raw.windows(4)
        .position(|window| window == b"\r\n\r\n")
        .map(|at| at + 2)
        .or_else(|| {
            raw.windows(2)
                .position(|window| window == b"\n\n")
                .map(|at| at + 1)
        })
}

#[cfg(test)]
mod tests;
