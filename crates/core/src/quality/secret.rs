//! Token detection that never repeats the token. A finding about a leaked
//! credential is itself written down — in a plan preview, in a lock of
//! findings an override binds to, in whatever the user pastes into an issue
//! — so the matched text must not travel with it. What travels is the
//! issuer's own prefix, which names the kind of key without being usable,
//! and a fingerprint that is stable enough to tell two leaks apart.

/// Prefixes that announce what a token is, with the least number of
/// characters that follow one in a real key. The length floor is what keeps
/// prose like "sk-learn" out of the results.
const PREFIXES: &[(&str, usize)] = &[
    ("sk-ant-", 24),
    ("sk-", 20),
    ("ghp_", 36),
    ("gho_", 36),
    ("ghu_", 36),
    ("ghs_", 36),
    ("ghr_", 36),
    ("github_pat_", 22),
    ("AKIA", 16),
    ("ASIA", 16),
    ("xoxb-", 24),
    ("xoxp-", 24),
    ("xoxa-", 24),
    ("glpat-", 20),
    ("AIza", 30),
];

/// The token in `value` that looks issued, if there is one. Matching is
/// case-sensitive: every prefix here is published in one exact casing.
pub fn find_secret(value: &str) -> Option<&str> {
    value
        .split(|c: char| !is_token_char(c))
        .find(|token| looks_issued(token))
}

/// The same text with every issued-looking token replaced by its
/// fingerprint. A rule that quotes a config value back to the user runs it
/// through here first, so no message, log or record can carry a usable key
/// even when the rule that found it was looking for something else.
pub fn redact(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    let mut start = 0;
    for (index, c) in value.char_indices() {
        if is_token_char(c) {
            continue;
        }
        push_token(&mut out, &value[start..index]);
        out.push(c);
        start = index + c.len_utf8();
    }
    push_token(&mut out, &value[start..]);
    out
}

fn push_token(out: &mut String, token: &str) {
    match looks_issued(token) {
        true => out.push_str(&fingerprint_secret(token)),
        false => out.push_str(token),
    }
}

fn looks_issued(token: &str) -> bool {
    PREFIXES.iter().any(|(prefix, min_tail)| {
        token
            .strip_prefix(prefix)
            .is_some_and(|tail| tail.len() >= *min_tail && tail.chars().all(is_token_char))
    })
}

fn is_token_char(c: char) -> bool {
    c.is_ascii_alphanumeric() || matches!(c, '-' | '_')
}

/// How a matched token is written down: the issuer's prefix, then a short
/// digest of the whole token. Two findings about the same key fingerprint
/// alike; nothing here can be used to authenticate as anyone.
///
/// The digest is [`super::DIGEST_CHARS`] wide because it lands in a
/// finding's message, and a message is half of what a finding *is*: the
/// token it stands for is a value a project chooses, so a narrow digest is
/// something to grind against until an injected finding wears a settled
/// one's sentence.
pub fn fingerprint_secret(token: &str) -> String {
    let prefix = PREFIXES
        .iter()
        .find(|(prefix, _)| token.starts_with(prefix))
        .map(|(prefix, _)| *prefix)
        .unwrap_or("");
    let digest: String = crate::hash::hash_bytes(token.as_bytes())
        .chars()
        .take(super::DIGEST_CHARS)
        .collect();
    format!("{prefix}…#{digest}")
}
