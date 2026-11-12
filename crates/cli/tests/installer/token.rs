//! `install.sh` given a GitHub token in `KENDEX_GITHUB_TOKEN`: which
//! requests carry it, to which hosts, and that no run prints it. Without one
//! the installer sends exactly the anonymous requests it always has.

use std::path::{Path, PathBuf};
use std::process::{Command, Output};

use super::{UNAME, posix_shell, repo_root, write_stub};
use crate::installer_message::value;
use crate::test_util::{self, SUDO_STUB, install_stub, rooted};

/// A value in GitHub's token alphabet and no real token's form.
const TOKEN: &str = "kendexfixturetoken0123456789";
const MAIN_BUILD: &str = "main-build-42-1-0123456789abcdef0123456789abcdef01234567";
const COMMIT: &str = "0123456789abcdef0123456789abcdef01234567";
const RELEASES: &str = "https://github.com/vanillagreencom/kendex/releases";
const API: &str = "https://api.github.com/repos/vanillagreencom/kendex/releases";

/// A release as api.github.com answers it, cut down from its answer for
/// v1.20.0 with the field order kept: each asset's `url` and `name` come
/// before the uploader, whose own `url` is an account, and the
/// `browser_download_url` comes last. The first asset is one the installer
/// never asks for, so a lookup that takes the wrong neighbour shows.
const RELEASE: &str = r#"{
  "url": "https://api.github.com/repos/vanillagreencom/kendex/releases/416601900",
  "html_url": "https://github.com/vanillagreencom/kendex/releases/tag/__TAG__",
  "id": 416601900,
  "tag_name": "__TAG__",
  "name": "__TAG__",
  "assets": [
    __ASSETS__
  ],
  "body": "Release notes, with a comma."
}
"#;

const ASSET: &str = r#"{
      "url": "https://api.github.com/repos/vanillagreencom/kendex/releases/assets/__ID__",
      "id": __ID__,
      "name": "__NAME__",
      "label": "",
      "uploader": {
        "login": "github-actions[bot]",
        "url": "https://api.github.com/users/github-actions%5Bbot%5D",
        "type": "Bot"
      },
      "content_type": "application/octet-stream",
      "state": "uploaded",
      "browser_download_url": "https://github.com/vanillagreencom/kendex/releases/download/__TAG__/__NAME__"
    }"#;

/// Every release here holds these assets; the id is how a test tells which
/// one the installer asked for.
const ASSETS: [(u32, &str); 4] = [
    (101, "digests-x86_64-unknown-linux-gnu.json"),
    (102, "kendex-x86_64-unknown-linux-gnu"),
    (103, "kendex_9.9.9_amd64.AppImage"),
    (104, "feed.json"),
];

fn release(tag: &str) -> String {
    let assets: Vec<String> = ASSETS
        .iter()
        .map(|(id, name)| {
            ASSET
                .replace("__ID__", &id.to_string())
                .replace("__NAME__", name)
        })
        .collect();
    RELEASE
        .replace("__ASSETS__", &assets.join(",\n    "))
        .replace("__TAG__", tag)
}

/// The main build's own feed, in the shape the release workflow writes.
fn feed() -> String {
    format!(
        "{{\n  \"commit\": \"{COMMIT}\",\n  \"version\": \"9.9.9+main.42.{COMMIT}\",\n  \"assets\": {{\n    \
         \"x86_64-unknown-linux-gnu\": \"{RELEASES}/download/{MAIN_BUILD}/kendex-x86_64-unknown-linux-gnu\"\n  }},\n  \
         \"apps\": {{\n    \"x86_64-unknown-linux-gnu\": \"{RELEASES}/download/{MAIN_BUILD}/kendex_9.9.9_amd64.AppImage\"\n  }}\n}}\n"
    )
}

/// The network, logging each call as `auth`, the URL, the Accept header and
/// the arguments with `-o` cut to the file name. `auth` is `yes` when curl
/// read the token's header from the config on standard input. With
/// `FAKE_CURL_FAIL` set every call fails with that HTTP status, as curl
/// `-f` does: exit 22, the status where `-w` asks for it. With
/// `FAKE_CURL_FLAKY` set to a status and an exit code, the first request
/// for the x86_64 Linux command fails that way and every later one answers.
const CURL: &str = r#"#!/usr/bin/env bash
config="" out="" url="" write="" accept="-" args=()
while [ $# -gt 0 ]; do
  case "$1" in
    -K) [ "$2" != - ] || config="$(cat)"; args+=("$1" "$2"); shift 2 ;;
    -o) out="$2"; args+=(-o "${2##*/}"); shift 2 ;;
    -w) write="$2"; args+=(-w "$2"); shift 2 ;;
    -H) case "$2" in "Accept: "*) accept="${2#Accept: }" ;; esac; args+=(-H "$2"); shift 2 ;;
    --proto) args+=("$1" "$2"); shift 2 ;;
    -*) args+=("$1"); shift ;;
    *) url="$1"; args+=("$1"); shift ;;
  esac
done
auth=no
case "$config" in *"Authorization: Bearer __TOKEN__"*) auth=yes ;; esac
printf '%s\t%s\t%s\t%s\n' "$auth" "$url" "$accept" "${args[*]}" >> "__FAKE__/requests"
if [ -n "${FAKE_CURL_FAIL:-}" ]; then
  [ -z "$write" ] || printf '%s' "$FAKE_CURL_FAIL"
  echo "curl: (22) The requested URL returned error: $FAKE_CURL_FAIL" >&2
  exit 22
fi
api=https://api.github.com/repos/vanillagreencom/kendex/releases
if [ -n "${FAKE_CURL_FLAKY:-}" ] && [ ! -e "__FAKE__/flaked" ]; then
  case "$url" in
    */releases/download/*/kendex-x86_64-unknown-linux-gnu|"$api/assets/102")
      : > "__FAKE__/flaked"
      read -r status code <<<"$FAKE_CURL_FLAKY"
      [ -z "$write" ] || printf '%s' "$status"
      echo "curl: ($code) The requested URL returned error: $status" >&2
      exit "$code" ;;
  esac
fi
case "$url" in
  https://github.com/vanillagreencom/kendex/releases/latest)
    printf '%s' https://github.com/vanillagreencom/kendex/releases/tag/v9.9.9; exit 0 ;;
  "$api/latest") cp "__FAKE__/releases/v9.9.9.json" "$out" ;;
  "$api/tags/"*)
    found="__FAKE__/releases/${url#"$api/tags/"}.json"
    [ -f "$found" ] || { [ -z "$write" ] || printf 404; exit 22; }
    cp "$found" "$out" ;;
  "$api/assets/104"|*/releases/download/*/feed.json) cp "__FAKE__/feed.json" "$out" ;;
  "$api/assets/"*|https://github.com/vanillagreencom/kendex/releases/download/*|https://raw.githubusercontent.com/*)
    printf '#!/bin/sh\necho stub\n' > "$out" ;;
  *) [ -z "$write" ] || printf 404; exit 22 ;;
esac
[ -z "$write" ] || printf 200
"#;

/// One call the fake curl logged.
#[derive(Debug, PartialEq)]
struct Request {
    auth: bool,
    url: String,
    accept: Option<String>,
    args: String,
}

/// What one installer run did.
struct Run {
    home: PathBuf,
    output: Output,
    requests: Vec<Request>,
    /// Each wait `sleep` was asked for, in order.
    sleeps: Vec<String>,
    _tmp: tempfile::TempDir,
}

impl Run {
    fn stdout(&self) -> String {
        String::from_utf8_lossy(&self.output.stdout).into_owned()
    }

    fn stderr(&self) -> String {
        String::from_utf8_lossy(&self.output.stderr).into_owned()
    }

    /// The installer's own `KEY=VALUE` lines from one stream, the fixture
    /// home spelled `<home>`: the part of its output a program reads.
    fn messages(&self, stream: &[u8]) -> Vec<String> {
        String::from_utf8_lossy(stream)
            .lines()
            .filter(|line| line.starts_with("install.sh: "))
            .map(|line| line.replace(&self.home.display().to_string(), "<home>"))
            .collect()
    }

    fn report(&self) -> String {
        format!(
            "status={:?}\nrequests={:#?}\nstdout:\n{}\nstderr:\n{}",
            self.output.status,
            self.requests,
            self.stdout(),
            self.stderr()
        )
    }
}

/// `script` run as Linux x86_64 with `args`, the token in the environment
/// when `token` is given, and every request failing with `fail` when given.
fn run(script: &Path, args: &[&str], token: Option<&str>, fail: Option<u16>) -> Run {
    run_flaky(script, args, token, fail, None)
}

/// The same run, with `FAKE_CURL_FLAKY` set to `flaky` when given. `sleep`
/// returns at once and logs each wait to `fake/sleeps`.
#[allow(clippy::unwrap_used, clippy::expect_used)]
fn run_flaky(
    script: &Path,
    args: &[&str],
    token: Option<&str>,
    fail: Option<u16>,
    flaky: Option<&str>,
) -> Run {
    let tmp = tempfile::tempdir().expect("tempdir");
    let home = rooted(&tmp);
    let fake = home.join("fake");
    let stubs = home.join("stub-bin");
    std::fs::create_dir_all(fake.join("releases")).unwrap();
    std::fs::create_dir_all(&stubs).unwrap();
    for tag in ["v9.9.9", MAIN_BUILD] {
        std::fs::write(fake.join(format!("releases/{tag}.json")), release(tag)).unwrap();
    }
    std::fs::write(fake.join("feed.json"), feed()).unwrap();
    write_stub(
        &stubs,
        "curl",
        &CURL
            .replace("__FAKE__", &fake.display().to_string())
            .replace("__TOKEN__", TOKEN),
    );
    write_stub(
        &stubs,
        "sleep",
        &format!(
            "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"{}\"\n",
            fake.join("sleeps").display()
        ),
    );
    write_stub(&stubs, "uname", UNAME);
    write_stub(&stubs, "sudo", SUDO_STUB);
    write_stub(&stubs, "install", &install_stub(&home));

    let mut command = Command::new(posix_shell());
    command
        .arg(script)
        .args(args)
        .env(
            "PATH",
            format!(
                "{}:{}/.local/bin:{}",
                stubs.display(),
                home.display(),
                std::env::var("PATH").unwrap_or_default()
            ),
        )
        .envs(test_util::fixture_env(&home))
        .env("XDG_DATA_HOME", home.join("share"))
        .env_remove("KENDEX_GITHUB_TOKEN")
        .env_remove("FAKE_CURL_FAIL")
        .env_remove("FAKE_CURL_FLAKY");
    if let Some(token) = token {
        command.env("KENDEX_GITHUB_TOKEN", token);
    }
    if let Some(status) = fail {
        command.env("FAKE_CURL_FAIL", status.to_string());
    }
    if let Some(flaky) = flaky {
        command.env("FAKE_CURL_FLAKY", flaky);
    }
    let output = command.output().expect("install.sh runs");
    let requests = std::fs::read_to_string(fake.join("requests"))
        .unwrap_or_default()
        .lines()
        .map(|line| {
            let mut fields = line.splitn(4, '\t');
            let mut next = || fields.next().expect("a logged field").to_owned();
            let (auth, url, accept, args) = (next(), next(), next(), next());
            Request {
                auth: auth == "yes",
                url,
                accept: (accept != "-").then_some(accept),
                args,
            }
        })
        .collect();
    let sleeps = std::fs::read_to_string(fake.join("sleeps"))
        .unwrap_or_default()
        .lines()
        .map(str::to_owned)
        .collect();
    Run {
        home,
        output,
        requests,
        sleeps,
        _tmp: tmp,
    }
}

fn install_sh() -> PathBuf {
    repo_root().join("install.sh")
}

fn icons(reference: &str) -> Vec<String> {
    ["32x32.png", "128x128.png", "128x128@2x.png", "icon.png"]
        .iter()
        .map(|icon| {
            format!(
                "https://raw.githubusercontent.com/vanillagreencom/kendex/{reference}/crates/app/icons/{icon}"
            )
        })
        .collect()
}

fn host(url: &str) -> &str {
    url.strip_prefix("https://")
        .and_then(|rest| rest.split('/').next())
        .unwrap_or(url)
}

const JSON: &str = "application/vnd.github+json";
const OCTETS: &str = "application/octet-stream";

/// A request as whether it carries the token, the URL and the Accept header.
type Sent = (bool, String, Option<&'static str>);

/// Each row: the installer's arguments, then every request it makes.
fn token_rows() -> Vec<(Vec<&'static str>, Vec<Sent>)> {
    let with_icons = |mut requests: Vec<Sent>, reference| {
        requests.extend(icons(reference).into_iter().map(|url| (false, url, None)));
        requests
    };
    vec![
        (
            vec![],
            with_icons(
                vec![
                    (true, format!("{API}/latest"), Some(JSON)),
                    (true, format!("{API}/assets/102"), Some(OCTETS)),
                    (true, format!("{API}/assets/103"), Some(OCTETS)),
                ],
                "v9.9.9",
            ),
        ),
        (
            vec!["--version", MAIN_BUILD],
            with_icons(
                vec![
                    (true, format!("{API}/tags/{MAIN_BUILD}"), Some(JSON)),
                    (true, format!("{API}/assets/104"), Some(OCTETS)),
                    (true, format!("{API}/assets/102"), Some(OCTETS)),
                    (true, format!("{API}/assets/103"), Some(OCTETS)),
                ],
                COMMIT,
            ),
        ),
    ]
}

/// github.com's release pages ignore a token, so the lookup and each
/// download go to api.github.com, which counts it. Nothing else gets it: not
/// the icons on raw.githubusercontent.com, and not the signed storage host
/// an asset redirects to, which curl reaches without the header unless
/// `--location-trusted` keeps it. A request carrying the token opens with
/// `-q`, which curl reads only as its first argument, so a caller's
/// `.curlrc` can neither add `location-trusted` nor print the header with
/// `verbose`.
#[test]
fn a_token_goes_to_github_alone() {
    for (args, expected) in token_rows() {
        let run = run(&install_sh(), &args, Some(TOKEN), None);
        assert!(run.output.status.success(), "{args:?}: {}", run.report());
        let observed: Vec<(bool, String, Option<&str>)> = run
            .requests
            .iter()
            .map(|request| (request.auth, request.url.clone(), request.accept.as_deref()))
            .collect();
        assert_eq!(observed, expected, "{args:?}: {}", run.report());
        for request in &run.requests {
            assert!(!request.args.contains(TOKEN), "{args:?}: {request:?}");
            assert!(
                !request.args.contains("--location-trusted"),
                "{args:?}: {request:?}"
            );
            assert!(
                request.args.contains("--proto =https"),
                "{args:?}: {request:?}"
            );
            if request.auth {
                assert!(
                    ["github.com", "api.github.com"].contains(&host(&request.url)),
                    "{args:?}: {request:?}"
                );
                assert!(
                    request.args.starts_with("-q -K - "),
                    "{args:?}: {request:?}"
                );
            }
        }
    }
}

/// Without a token the installer sends what it sent before the option
/// existed, argument for argument, and says the same: each row's requests
/// and messages were read off a run of the installer before
/// `KENDEX_GITHUB_TOKEN`, and a release download since asks for the HTTP
/// status its retry reads. An empty value is no token.
#[test]
fn without_a_token_the_installer_sends_what_it_always_has() {
    let download = |tag: &str, file: &str, name: &str| {
        format!("-fSL --proto =https -w %{{http_code}} -o {file} {RELEASES}/download/{tag}/{name}")
    };
    let icon_requests = |reference| {
        ["32x32", "128x128", "256x256", "512x512"]
            .iter()
            .zip(icons(reference))
            .map(|(size, url)| format!("-fsSL --proto =https -o {size}.png {url}"))
            .collect::<Vec<_>>()
    };
    let mut latest = vec![
        format!("-fsSLI -o null -w %{{url_effective}} {RELEASES}/latest"),
        download("v9.9.9", "kendex", "kendex-x86_64-unknown-linux-gnu"),
        download("v9.9.9", "kendex.AppImage", "kendex_9.9.9_amd64.AppImage"),
    ];
    latest.extend(icon_requests("v9.9.9"));
    let mut main_build = vec![
        download(MAIN_BUILD, "feed.json", "feed.json"),
        download(MAIN_BUILD, "kendex", "kendex-x86_64-unknown-linux-gnu"),
        download(MAIN_BUILD, "kendex.AppImage", "kendex_9.9.9_amd64.AppImage"),
    ];
    main_build.extend(icon_requests(COMMIT));
    let said = vec![
        "install.sh: command-download=x86_64-unknown-linux-gnu",
        "install.sh: command-installed=<home>/.local/bin/kendex",
        "install.sh: app-download=amd64",
        "install.sh: app-installed=<home>/share/kendex/kendex.AppImage",
    ];
    for (args, token, requests) in [
        (vec![], None, &latest),
        (vec![], Some(""), &latest),
        (vec!["--version", MAIN_BUILD], None, &main_build),
    ] {
        let run = run(&install_sh(), &args, token, None);
        let row = format!("{args:?} token={token:?}");
        assert!(run.output.status.success(), "{row}: {}", run.report());
        assert!(
            run.requests.iter().all(|request| !request.auth),
            "{row}: {}",
            run.report()
        );
        let sent: Vec<&str> = run.requests.iter().map(|r| r.args.as_str()).collect();
        assert_eq!(&sent, requests, "{row}: {}", run.report());
        assert_eq!(
            run.messages(&run.output.stdout),
            said,
            "{row}: {}",
            run.report()
        );
        assert_eq!(
            run.messages(&run.output.stderr),
            Vec::<String>::new(),
            "{row}: {}",
            run.report()
        );
    }
}

/// A run that fails: its arguments, the token, the HTTP status every
/// request fails with, and the message it stops on, with its exit code.
struct Stop {
    args: &'static [&'static str],
    token: &'static str,
    fail: Option<u16>,
    key: &'static str,
    value: String,
    code: i32,
}

fn stops() -> [Stop; 5] {
    let pinned: &[&str] = &["--version", "9.9.9"];
    [
        Stop {
            args: &[],
            token: TOKEN,
            fail: Some(504),
            key: "release-unavailable",
            value: format!("{API}/latest"),
            code: 1,
        },
        Stop {
            args: &[],
            token: TOKEN,
            fail: Some(401),
            key: "github-token-rejected",
            value: format!("{API}/latest"),
            code: 1,
        },
        Stop {
            args: pinned,
            token: TOKEN,
            fail: Some(504),
            key: "command-download-url",
            value: format!("{RELEASES}/download/v9.9.9/kendex-x86_64-unknown-linux-gnu"),
            code: 1,
        },
        Stop {
            args: pinned,
            token: TOKEN,
            fail: Some(401),
            key: "github-token-rejected",
            value: format!("{API}/tags/v9.9.9"),
            code: 1,
        },
        // A quote would end the header in curl's config and begin an option.
        Stop {
            args: &[],
            token: "kendex\"fixture",
            fail: None,
            key: "github-token-invalid",
            value: "KENDEX_GITHUB_TOKEN".to_owned(),
            code: 2,
        },
    ]
}

/// However the install fails, the token is in neither stream: not in curl's
/// errors, not in the installer's messages, not in the URL it reports.
/// A refused token stops the install by name instead of falling back to
/// anonymous requests.
#[test]
fn a_failing_install_never_prints_the_token() {
    for stop in stops() {
        let run = run(&install_sh(), stop.args, Some(stop.token), stop.fail);
        let row = format!("{:?} fail={:?}", stop.args, stop.fail);
        assert_eq!(
            run.output.status.code(),
            Some(stop.code),
            "{row}: {}",
            run.report()
        );
        assert_eq!(
            value(&run.output.stderr, stop.key),
            Some(stop.value.as_str()),
            "{row}: {}",
            run.report()
        );
        for stream in [run.stdout(), run.stderr()] {
            assert!(!stream.contains(stop.token), "{row}: {}", run.report());
        }
        if stop.fail == Some(401) {
            assert!(
                run.requests.iter().all(|request| request.auth),
                "{row}: {}",
                run.report()
            );
        }
        if stop.code == 2 {
            assert_eq!(run.requests, Vec::new(), "{row}: {}", run.report());
        }
    }
}

/// Which check a copy of `install.sh` with one rule taken out turns red.
enum Breaks {
    /// The token row: not one request carries the token.
    Carried,
    /// The leak row: the token reaches stderr.
    Printed,
    /// The token row: a request carrying the token reads the caller's
    /// curl config, because `-q` is not its first argument.
    Defaults,
}

/// The controls for the rows above. Reading no token is the installer
/// before this option.
#[test]
#[allow(clippy::unwrap_used)]
fn each_token_rule_breaks_its_own_check() {
    let source = std::fs::read_to_string(install_sh()).unwrap();
    for (from, to, breaks) in [
        (
            "github_token=\"${KENDEX_GITHUB_TOKEN:-}\"\n",
            "github_token=\"\"\n",
            Breaks::Carried,
        ),
        (
            "message github-token-rejected \"$url\"",
            "message github-token-rejected \"$url $github_token\"",
            Breaks::Printed,
        ),
        ("| curl -q -K - ", "| curl -K - ", Breaks::Defaults),
    ] {
        assert_eq!(
            source.matches(from).count(),
            1,
            "install.sh holds {from:?} once"
        );
        let dir = tempfile::tempdir().unwrap();
        let script = rooted(&dir).join("install-mutant.sh");
        std::fs::write(&script, source.replace(from, to)).unwrap();
        match breaks {
            Breaks::Carried => {
                let run = run(&script, &[], Some(TOKEN), None);
                assert!(
                    run.requests.iter().all(|request| !request.auth),
                    "{from:?}: {}",
                    run.report()
                );
            }
            Breaks::Printed => {
                let run = run(&script, &[], Some(TOKEN), Some(401));
                assert!(run.stderr().contains(TOKEN), "{from:?}: {}", run.report());
            }
            Breaks::Defaults => {
                let run = run(&script, &[], Some(TOKEN), None);
                let carried: Vec<&Request> =
                    run.requests.iter().filter(|request| request.auth).collect();
                assert!(
                    !carried.is_empty()
                        && carried
                            .iter()
                            .all(|request| !request.args.starts_with("-q ")),
                    "{from:?}: {}",
                    run.report()
                );
            }
        }
    }
}

/// A release download that GitHub answers with a temporary error is tried
/// again, whatever exit code curl gives it: 56 is how a macOS runner's curl
/// reported the 504 in merge-group run 42469437922, which curl's own
/// `--retry` passes over. Any other error stops at once. Each row: the
/// token, the first command request's status and curl exit code, and
/// whether the install then succeeds.
#[test]
fn a_temporary_download_error_is_tried_again_and_no_other_is() {
    let anonymous = format!("{RELEASES}/download/v9.9.9/kendex-x86_64-unknown-linux-gnu");
    let carried = format!("{API}/assets/102");
    for (token, flaky, installs) in [
        (None, "504 56", true),
        (None, "503 22", true),
        (Some(TOKEN), "504 22", true),
        (None, "404 22", false),
        (Some(TOKEN), "404 22", false),
    ] {
        let run = run_flaky(&install_sh(), &[], token, None, Some(flaky));
        let row = format!("token={} {flaky}", token.is_some());
        let command = if token.is_some() {
            &carried
        } else {
            &anonymous
        };
        let tries = run
            .requests
            .iter()
            .filter(|request| &request.url == command)
            .count();
        if installs {
            assert!(run.output.status.success(), "{row}: {}", run.report());
            assert_eq!(tries, 2, "{row}: {}", run.report());
            assert_eq!(run.sleeps.len(), 1, "{row}: {}", run.report());
            assert_eq!(
                value(&run.output.stderr, "download-retry"),
                flaky.split(' ').next(),
                "{row}: {}",
                run.report()
            );
        } else {
            assert_eq!(run.output.status.code(), Some(1), "{row}: {}", run.report());
            assert_eq!(tries, 1, "{row}: {}", run.report());
            assert_eq!(run.sleeps, Vec::<String>::new(), "{row}: {}", run.report());
            assert_eq!(
                value(&run.output.stderr, "command-download-failed"),
                Some("22"),
                "{row}: {}",
                run.report()
            );
        }
    }
}

/// The control for the rows above: an installer that tries each download
/// once, as it did before the retry, fails the row a 504 should survive.
#[test]
#[allow(clippy::unwrap_used)]
fn one_try_fails_the_retry_row() {
    let source = std::fs::read_to_string(install_sh()).unwrap();
    let from = "download_attempts=8\n";
    assert_eq!(
        source.matches(from).count(),
        1,
        "install.sh holds {from:?} once"
    );
    let dir = tempfile::tempdir().unwrap();
    let script = rooted(&dir).join("install-mutant.sh");
    std::fs::write(&script, source.replace(from, "download_attempts=1\n")).unwrap();
    let run = run_flaky(&script, &[], None, None, Some("504 56"));
    assert_eq!(run.output.status.code(), Some(1), "{}", run.report());
    assert_eq!(
        value(&run.output.stderr, "command-download-failed"),
        Some("56"),
        "{}",
        run.report()
    );
}
