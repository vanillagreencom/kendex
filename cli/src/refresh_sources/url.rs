//! Remote URL hygiene: how a source string is SPELLED, which transports are
//! accepted, and what a diagnostic may echo back.
//!
//! Every string here is one a lock file recorded verbatim, so every path out
//! of this module either redacts userinfo and query secrets or escapes the
//! control characters a terminal would act on. What a URL IDENTIFIES —
//! which repository, which cache entry — is [`super`]'s.

use anyhow::{Result, bail};

// ---------------------------------------------------------------------------
// Remote URL hygiene
// ---------------------------------------------------------------------------

/// A source as it may appear in diagnostics: shorthand as-is, URLs with any
/// userinfo secret and any query/fragment replaced, and every control or
/// direction-changing character escaped — a lock file records source strings
/// verbatim, and a refusal that echoed one would put its terminal escapes on
/// vstack's own stderr.
pub(crate) fn remote_source_display(source: &str) -> String {
    // Only an ssh spelling names a remote with a bare `user@`. Where the
    // grammar says otherwise — or where it says nothing at all, which is how a
    // local path reaches here — the two answers differ, so the question is
    // asked of the ORIGINAL text once and carried through the redactions.
    escape_unprintable(&redact_stray_userinfo(
        &redact_remote_query(&redact_remote_userinfo(source)),
        spelling_allows_bare_username(source),
    ))
}

/// Whether a bare `user@` in `source` names an account rather than a token.
///
/// Only the ssh spellings carry a username. A string the grammar cannot parse
/// gets the benefit of the doubt ONLY when it names no transport at all —
/// which is what a local path looks like: `https:/TOKEN@host/repo` is
/// malformed enough to parse as neither URL nor scp-like, and reading its
/// token as a username printed it verbatim in the refusal.
fn spelling_allows_bare_username(source: &str) -> bool {
    if let Some(url) = parse_remote_url(source) {
        return url.allows_bare_username();
    }
    scheme_prefix(source).is_none_or(|scheme| {
        scheme.eq_ignore_ascii_case("ssh") || scheme.eq_ignore_ascii_case("git+ssh")
    })
}

/// The scheme names git could be handed, supported or refused. A refused one
/// still names a transport — `git://` is a URL vstack will not use, not a
/// directory.
const TRANSPORT_SCHEMES: &[&str] = &[
    "https", "http", "ssh", "git+ssh", "git", "file", "ftp", "ftps", "rsync",
];

/// Whether `source` is spelled as if it names a transport, however malformed.
///
/// A string that opens with a transport's scheme is an attempt at a URL, so it
/// names SOMETHING: a caller walking past it because the strict parser could
/// not read it would install from a different source than the one recorded —
/// the same refused-is-not-absent fail-open closed everywhere else. The scheme
/// must be a real one, because `:` is an ordinary character in a POSIX path
/// and a missing local directory called `foo:bar` is a local candidate that
/// names nothing, which is the one outcome the chain may walk past.
///
/// Deliberately stricter than the check [`spelling_allows_bare_username`]
/// makes: over-redacting a diagnostic costs nothing, over-refusing a source
/// costs the user their install.
pub(crate) fn names_a_transport(source: &str) -> bool {
    scheme_prefix(source.trim()).is_some_and(|scheme| {
        TRANSPORT_SCHEMES
            .iter()
            .any(|t| scheme.eq_ignore_ascii_case(t))
    })
}

/// The `scheme:` a string opens with. A one-character scheme is a Windows
/// drive letter, which names no transport.
fn scheme_prefix(source: &str) -> Option<&str> {
    let scheme = &source[..source.find(':')?];
    let valid = scheme.len() > 1
        && scheme.starts_with(|ch: char| ch.is_ascii_alphabetic())
        && scheme
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '+' | '-' | '.'));
    valid.then_some(scheme)
}

/// Redact anything shaped like `user:secret@` wherever it sits, after the
/// authority has had its own pass.
///
/// A malformed URL puts a credential where the authority redaction cannot see
/// it — `https:///user:token@host/repo` parses with an EMPTY authority, so the
/// secret is path text and was echoed verbatim. Redaction has to be
/// conservative about a shape it could not parse, including for a URL that is
/// about to be refused: the refusal prints it.
fn redact_stray_userinfo(text: &str, bare_username_is_a_username: bool) -> String {
    text.split_inclusive('/')
        .map(|segment| {
            let Some(at) = segment.rfind('@') else {
                return segment.to_string();
            };
            let (userinfo, host) = segment.split_at(at);
            match userinfo.split_once(':') {
                // A bare `user@host` is how an ssh remote is spelled — and how
                // a token-only credential is spelled everywhere else, which is
                // why the transport decides and not the punctuation.
                None if bare_username_is_a_username => segment.to_string(),
                None => format!("<redacted>{host}"),
                Some((username, _)) => format!("{username}:<redacted>{host}"),
            }
        })
        .collect()
}

/// Escape what a terminal would act on rather than print.
pub(crate) fn escape_unprintable(text: &str) -> String {
    fn is_unprintable(ch: char) -> bool {
        ch.is_control()
            || matches!(ch,
                '\u{200b}'..='\u{200f}' | '\u{202a}'..='\u{202e}' | '\u{2066}'..='\u{2069}' | '\u{feff}')
    }
    if !text.chars().any(is_unprintable) {
        return text.to_string();
    }
    text.chars()
        .map(|ch| {
            if is_unprintable(ch) {
                format!("\\u{{{:x}}}", ch as u32)
            } else {
                ch.to_string()
            }
        })
        .collect()
}

/// The transports vstack hands to git. Anything else — `git://`, which is
/// unauthenticated and unencrypted, and any unknown scheme, which makes git run
/// a `git-remote-<scheme>` helper — is refused before a process sees it. `file`
/// is here because a local clone is how a source is exercised offline.
const SUPPORTED_TRANSPORTS: &[&str] = &["https", "ssh", "git+ssh", "file"];

/// Refuse a URL whose transport vstack does not hand to git, and one that names
/// no host to reach over a network transport.
///
/// The hostless form is not merely malformed: `https:///user:token@host/repo`
/// parses with an empty authority, so its credential sits in the path where
/// neither the credential refusal nor the authority redaction could see it, and
/// git was handed the token as-is.
pub(crate) fn reject_unsupported_transport(url: &str) -> Result<()> {
    let Some(parsed) = parse_remote_url(url) else {
        return Ok(());
    };
    let display = remote_source_display(url);
    // `file://` is the one spelling that legitimately names no host.
    if parsed.host.is_empty() && !parsed.scheme.eq_ignore_ascii_case("file") {
        bail!("remote source URL names no host: {display}");
    }
    // The scp-like spelling carries no scheme and is ssh by definition.
    if parsed.scp_like() {
        return Ok(());
    }
    if !SUPPORTED_TRANSPORTS
        .iter()
        .any(|transport| parsed.scheme.eq_ignore_ascii_case(transport))
    {
        bail!(
            "remote source transport `{}` is not supported: {display}. Use https, ssh or git+ssh",
            escape_unprintable(parsed.scheme)
        );
    }
    Ok(())
}

/// Refuse a git URL that carries a credential. Userinfo on a non-ssh scheme
/// (`https://token@host/...`), a `user:secret@` pair on any scheme, or a query
/// or fragment (`...?access_token=...`) would hand the secret to every git
/// process and to every diagnostic that echoes the origin. A bare username on
/// an ssh scheme (`ssh://git@host/...`) is how ssh remotes are spelled and is
/// kept.
pub(crate) fn reject_credential_bearing_git_url(url: &str) -> Result<()> {
    if url.contains('?') || url.contains('#') {
        bail!(
            "remote source URLs with a query or fragment are not supported: {}. Use SSH keys, gh auth login, or a Git credential helper instead.",
            remote_source_display(url)
        );
    }
    let Some(parts) = parse_remote_url(url) else {
        return Ok(());
    };
    if parts.userinfo.is_empty() {
        return Ok(());
    }
    if !parts.allows_bare_username() || parts.userinfo.contains(':') {
        bail!(
            "credential-bearing remote source URLs are not supported: {}. Use SSH keys, gh auth login, or a Git credential helper instead.",
            remote_source_display(url)
        );
    }
    Ok(())
}

/// Replace a URL query/fragment with a marker. Git clone URLs have no
/// legitimate use for either, and both are places a token gets carried.
fn redact_remote_query(url: &str) -> String {
    // A local PATH has no query and no fragment: `?` and `#` are ordinary
    // characters in one, and redacting them corrupted the path rather than
    // protecting anything — a remedy command then named a directory that does
    // not exist. Every other spelling can carry a token there, including the
    // ones no parser accepts, which is why this asks about the shape and not
    // about whether a parser succeeded.
    if spelling_is_a_local_path(url) {
        return url.to_string();
    }
    match url.find(['?', '#']) {
        Some(index) => format!("{}<redacted>", &url[..=index]),
        None => url.to_string(),
    }
}

/// The spellings that name a filesystem path and therefore carry no query:
/// absolute for the running platform, `~`-tilde, or explicitly relative. The
/// same shapes [`crate::config`] treats as local when it reads a registry
/// entry.
fn spelling_is_a_local_path(source: &str) -> bool {
    std::path::Path::new(source).is_absolute()
        || source.starts_with('/')
        || source.starts_with('~')
        || source.starts_with("./")
        || source.starts_with("../")
}

/// One parse of the remote-URL grammar, for every question asked about a
/// source: is it a URL at all, what is its authority, does it carry a
/// credential, how is it displayed, and which repository does it name. Four
/// hand-rolled splitters used to answer those separately and disagreed on
/// where userinfo ends — the scp-like `user:secret@host:path` had no authority
/// by one of them, so its secret was neither refused nor redacted.
pub(super) struct RemoteUrl<'a> {
    /// Empty for the scp-like spelling, which carries no scheme.
    pub(super) scheme: &'a str,
    /// `[userinfo@]host` — never the path, and never a port-less prefix of it.
    pub(super) authority: &'a str,
    /// Everything before the authority's last `@`; empty when it has none.
    pub(super) userinfo: &'a str,
    pub(super) host: &'a str,
    /// The repository path, without the `/` or scp `:` that introduces it.
    pub(super) path: &'a str,
    /// The input up to where the authority starts, and from where it ends —
    /// enough to rebuild the input with a redacted userinfo.
    prefix: &'a str,
    suffix: &'a str,
}

impl RemoteUrl<'_> {
    /// The `[user@]host:path` spelling, which carries no scheme and is ssh.
    fn scp_like(&self) -> bool {
        self.scheme.is_empty()
    }

    /// Whether a bare `user@` is how this spelling names a remote rather than
    /// a credential. Both ssh spellings carry a username; nothing else does.
    fn allows_bare_username(&self) -> bool {
        self.scp_like()
            || self.scheme.eq_ignore_ascii_case("ssh")
            || self.scheme.eq_ignore_ascii_case("git+ssh")
    }

    /// The transport this spelling reaches the host over, in one name per
    /// transport: the scp-like form and `git+ssh://` are both ssh.
    pub(super) fn transport(&self) -> String {
        if self.allows_bare_username() {
            return "ssh".to_string();
        }
        self.scheme.to_ascii_lowercase()
    }
}

pub(super) fn parse_remote_url(input: &str) -> Option<RemoteUrl<'_>> {
    if let Some(scheme_end) = input.find("://") {
        let scheme = &input[..scheme_end];
        if scheme.is_empty()
            || !scheme
                .chars()
                .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '+' | '-' | '.'))
        {
            return None;
        }
        let authority_start = scheme_end + 3;
        // The authority runs to the first `/` and nothing else: stopping at
        // whitespace made a malformed `user:tok en@host` URL parse as having
        // no userinfo at all, so its secret was printed in full.
        let authority_end = input[authority_start..]
            .find('/')
            .map(|index| authority_start + index)
            .unwrap_or(input.len());
        let authority = &input[authority_start..authority_end];
        let (userinfo, host) = split_authority(authority);
        let suffix = &input[authority_end..];
        return Some(RemoteUrl {
            scheme,
            authority,
            userinfo,
            host,
            path: suffix.strip_prefix('/').unwrap_or(""),
            prefix: &input[..authority_start],
            suffix,
        });
    }
    // scp-like `[user@]host:path` — an `@` and a `:` before the first `/`.
    let head_end = input.find('/').unwrap_or(input.len());
    let head = &input[..head_end];
    if !head.contains('@') || !head.contains(':') {
        return None;
    }
    // Everything before the LAST `@` is userinfo here too: reading the first
    // `:` as the host separator instead put a `user:secret@host` credential
    // beyond every check.
    let at = head.rfind('@')?;
    let authority_end = input[at + 1..]
        .find(':')
        .map(|index| at + 1 + index)
        .unwrap_or(head_end);
    let authority = &input[..authority_end];
    let (userinfo, host) = split_authority(authority);
    let suffix = &input[authority_end..];
    Some(RemoteUrl {
        scheme: "",
        authority,
        userinfo,
        host,
        path: suffix.strip_prefix(':').unwrap_or(""),
        prefix: "",
        suffix,
    })
}

fn split_authority(authority: &str) -> (&str, &str) {
    match authority.rfind('@') {
        Some(at) => (&authority[..at], &authority[at + 1..]),
        None => ("", authority),
    }
}

/// Redact the secret part of a URL's userinfo, keeping a legitimate username.
pub(crate) fn redact_remote_userinfo(input: &str) -> String {
    let Some(parts) = parse_remote_url(input) else {
        return input.to_string();
    };
    if parts.userinfo.is_empty() {
        return input.to_string();
    }
    let redacted_userinfo = if let Some((username, _)) = parts.userinfo.split_once(':') {
        if username.is_empty() {
            "<redacted>".to_string()
        } else {
            format!("{username}:<redacted>")
        }
    } else if parts.allows_bare_username() {
        parts.userinfo.to_string()
    } else {
        "<redacted>".to_string()
    };
    format!(
        "{}{}@{}{}",
        parts.prefix, redacted_userinfo, parts.host, parts.suffix
    )
}
