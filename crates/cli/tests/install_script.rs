//! `install.sh` platform detection: every release lane's host picks its own
//! CLI binary and, on Linux, its own AppImage. Runs the real script with a
//! fake `uname` and a `curl` that records what it was asked for.

#![cfg(unix)]

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;

#[path = "../../test_util.rs"]
mod test_util;
use test_util::{SUDO_STUB, install_stub, rooted};

#[allow(clippy::unwrap_used)]
fn write_exe(path: &Path, body: &str) {
    fs::write(path, body).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
}

/// Runs install.sh as `os`/`arch` and returns every URL curl was handed.
fn requested_urls(os: &str, arch: &str) -> String {
    let (output, urls) = run_install(os, arch, None);
    assert!(
        output.status.success(),
        "install.sh failed for {os} {arch}:\n{}",
        String::from_utf8_lossy(&output.stderr)
    );
    urls
}

/// Runs install.sh as `os`/`arch`; `fail` makes the fake curl exit with the
/// given code for any URL containing the given text.
#[allow(clippy::unwrap_used)]
fn run_install(os: &str, arch: &str, fail: Option<(&str, i32)>) -> (std::process::Output, String) {
    let tmp = tempfile::tempdir().unwrap();
    run_install_in(os, arch, fail, tmp.path(), &[])
}

/// The same run against a home the caller keeps, for a test that reads what
/// the script left behind rather than only what it fetched.
#[allow(clippy::unwrap_used)]
fn run_install_at(os: &str, arch: &str, home: &Path) -> (std::process::Output, String) {
    run_install_in(os, arch, None, home, &[])
}

/// What `uname -s` answers on the machine running these tests.
///
/// A test that reads back what the script wrote has to drive the script as
/// this host: `install.sh` picks its data directory from `uname`, `Env`
/// picks the same one from the target it was built for, and told `Linux` on
/// a mac the script writes under `.local/share` while the resolver reads
/// `Library/Application Support`. One finds nothing there and reads it as a
/// script that recorded nothing; the other finds nothing there and reads it
/// as the record correctly withheld.
const HOST_UNAME: &str = match cfg!(target_os = "macos") {
    true => "Darwin",
    false => "Linux",
};

#[allow(clippy::unwrap_used)]
fn run_install_in(
    os: &str,
    arch: &str,
    fail: Option<(&str, i32)>,
    home: &Path,
    path_ahead: &[&str],
) -> (std::process::Output, String) {
    let fake = home.join("fake-bin");
    let bindir = home.join(".local/bin");
    fs::create_dir_all(&fake).unwrap();
    fs::create_dir_all(&bindir).unwrap();
    write_exe(
        &fake.join("uname"),
        &format!("#!/bin/sh\ncase \"$1\" in -s) echo {os} ;; -m) echo {arch} ;; esac\n"),
    );
    // The host's own `PATH` is appended below, so both commands the script
    // writes through resolve outside the fixture. Neither may reach past it.
    write_exe(&fake.join("sudo"), SUDO_STUB);
    write_exe(&fake.join("install"), &install_stub(home));
    // Logs the URL; `-o FILE` gets a runnable stand-in for the download,
    // and the release lookup gets a tag.
    let miss = fail.map_or(String::new(), |(url, code)| {
        format!("case \"$url\" in *{url}*) exit {code} ;; esac\n")
    });
    write_exe(
        &fake.join("curl"),
        &format!(
            "#!/bin/sh\nout=\"\"\nwhile [ $# -gt 0 ]; do case \"$1\" in -o) out=\"$2\"; shift 2 ;; *) url=\"$1\"; shift ;; esac; done\n\
             echo \"$url\" >> \"{log}\"\n{miss}\
             if [ -n \"$out\" ]; then printf '#!/bin/sh\\necho v9\\n' > \"$out\"; else echo '\"tag_name\": \"v9.9.9\"'; fi\n",
            log = home.join("urls.txt").display()
        ),
    );
    let script = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../install.sh");
    let output = Command::new("bash")
        .arg(script)
        .env_clear()
        .env("HOME", home)
        .env("KENDEX_REAL_HOME", "1")
        .env(
            "PATH",
            // `path_ahead` sits between the fake tools and the home
            // `bindir`, so a caller can put another of the script's
            // candidates in front of the one it would otherwise find.
            format!(
                "{}:{}{}:{}",
                fake.display(),
                path_ahead
                    .iter()
                    .map(|dir| format!("{dir}:"))
                    .collect::<String>(),
                bindir.display(),
                std::env::var("PATH").unwrap_or_default()
            ),
        )
        .output()
        .unwrap();
    let urls = fs::read_to_string(home.join("urls.txt")).unwrap_or_default();
    (output, urls)
}

#[test]
#[allow(clippy::unwrap_used)]
fn each_release_host_downloads_its_own_binary() {
    for (os, arch, target) in [
        ("Linux", "x86_64", "x86_64-unknown-linux-gnu"),
        ("Linux", "amd64", "x86_64-unknown-linux-gnu"),
        ("Linux", "aarch64", "aarch64-unknown-linux-gnu"),
        ("Linux", "arm64", "aarch64-unknown-linux-gnu"),
        ("Darwin", "arm64", "aarch64-apple-darwin"),
        ("Darwin", "aarch64", "aarch64-apple-darwin"),
        ("Darwin", "x86_64", "x86_64-apple-darwin"),
    ] {
        let urls = requested_urls(os, arch);
        assert!(
            urls.contains(&format!("/download/v9.9.9/kendex-{target}\n")),
            "{os} {arch} fetched:\n{urls}"
        );
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn linux_picks_the_appimage_built_for_its_architecture() {
    let urls = requested_urls("Linux", "x86_64");
    assert!(urls.contains("/kendex_9.9.9_amd64.AppImage"), "{urls}");
    let urls = requested_urls("Linux", "aarch64");
    assert!(urls.contains("/kendex_9.9.9_aarch64.AppImage"), "{urls}");
    let urls = requested_urls("Darwin", "x86_64");
    assert!(!urls.contains(".AppImage"), "{urls}");
}

/// The matrix lanes and the feed.json keys are two lists in release.yml;
/// a lane missing from either leaves that host's `kendex update` with no
/// asset to find.
#[test]
#[allow(clippy::unwrap_used)]
fn release_matrix_and_feed_name_the_same_targets() {
    let workflow = fs::read_to_string(
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../.github/workflows/release.yml"),
    )
    .unwrap();
    let mut lanes: Vec<&str> = workflow
        .lines()
        .filter_map(|l| l.trim().strip_prefix("target: "))
        .collect();
    let mut feed: Vec<&str> = workflow
        .lines()
        .filter_map(|l| {
            let l = l.trim().strip_prefix('"')?;
            let (key, rest) = l.split_once("\": \"${base}/kendex-")?;
            rest.starts_with(key).then_some(key)
        })
        .collect();
    lanes.sort();
    feed.sort();
    assert_eq!(
        lanes,
        [
            "aarch64-apple-darwin",
            "aarch64-unknown-linux-gnu",
            "x86_64-apple-darwin",
            "x86_64-pc-windows-msvc",
            "x86_64-unknown-linux-gnu",
        ]
    );
    assert_eq!(lanes, feed);
}

/// curl exits 22 on an HTTP error: the release exists but has no such asset.
#[test]
fn a_release_without_this_target_says_so_instead_of_a_bare_curl_error() {
    let (output, _) = run_install("Darwin", "x86_64", Some(("kendex-x86_64-apple-darwin", 22)));
    assert_eq!(output.status.code(), Some(1));
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("could not download kendex-x86_64-apple-darwin from"),
        "{stderr}"
    );
    assert!(
        stderr.contains("release v9.9.9 may have no build for x86_64-apple-darwin"),
        "{stderr}"
    );
    // The script stops at its own message; a crash on the next step would
    // exit 1 too, but through chmod complaining about the missing file.
    assert!(!stderr.contains("chmod"), "{stderr}");
}

/// curl exits 7 when it cannot connect: the release is not to blame, so
/// the no-build hint stays out.
#[test]
fn a_network_failure_does_not_blame_the_release() {
    let (output, _) = run_install("Darwin", "x86_64", Some(("kendex-x86_64-apple-darwin", 7)));
    assert_eq!(output.status.code(), Some(1));
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("could not download kendex-x86_64-apple-darwin from"),
        "{stderr}"
    );
    assert!(!stderr.contains("may have no build"), "{stderr}");
    assert!(!stderr.contains("chmod"), "{stderr}");
}

/// Every directory `install.sh` can install the command into, read out of
/// the script's own selection rather than restated here. A shape this
/// cannot parse fails the same way a changed destination does, because a
/// silent no-match would be the drift it exists to catch.
#[allow(clippy::unwrap_used)]
fn installer_bin_dirs(script: &str) -> Vec<String> {
    let chosen_from = script
        .lines()
        .find_map(|line| {
            line.trim()
                .strip_prefix("for candidate in ")?
                .strip_suffix("; do")
        })
        .expect("install.sh picks its bindir from a `for candidate in ...; do` list");
    // The fallback when none of them is on PATH. Written as its own
    // assignment, so it is read as its own line.
    let fallback = script
        .lines()
        .find_map(|line| {
            line.trim()
                .strip_prefix(r#"[ -n "$bindir" ] || bindir=""#)?
                .strip_suffix('"')
        })
        .expect("install.sh falls back to a bindir when none is on PATH");
    let mut dirs: Vec<String> = chosen_from
        .split_whitespace()
        .chain(std::iter::once(fallback))
        .map(|dir| dir.trim_matches('"').to_owned())
        .collect();
    dirs.dedup();
    assert!(!dirs.is_empty(), "install.sh named no bindir");
    dirs
}

/// The one fact `install.sh` and `kendex_core::command_update` both hold:
/// where the command is installed. The app looks the command up to carry
/// it across, and a launcher's `PATH` need not carry the installer's
/// directory, so the fallback roots are what finds it there. If the
/// installer moves its destination and this list does not follow, an
/// app-driven update stops finding the command and moves the app alone.
///
/// Read against the script itself, so the divergence fails here rather
/// than on a machine.
#[test]
#[allow(clippy::unwrap_used)]
fn every_directory_the_installer_can_choose_is_a_candidate() {
    let script = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../install.sh");
    let home = Path::new("/home/pat");
    // No PATH, so what comes back is the fallback list and nothing else —
    // the case this contract is about.
    let candidates = kendex_core::command_update::command_candidates(home, None);

    for dir in installer_bin_dirs(&fs::read_to_string(&script).unwrap()) {
        let expanded = PathBuf::from(dir.replace("$HOME", &home.display().to_string()));
        assert!(
            candidates
                .iter()
                .any(|found| found.parent() == Some(&expanded)),
            "install.sh can install into {}, which no candidate covers: {candidates:?}",
            expanded.display()
        );
    }
}

/// The invocation `install.sh` publishes for itself, read out of the
/// script's own header rather than restated here. A header this cannot
/// parse fails the same way a changed command does, because a silent
/// no-match would be the drift it exists to catch.
#[allow(clippy::unwrap_used)]
fn published_invocation(script: &str) -> String {
    script
        .lines()
        .find_map(|line| {
            let shown = line.strip_prefix('#')?.trim();
            (shown.starts_with("curl ") && shown.ends_with("| sh")).then(|| shown.to_owned())
        })
        .expect("install.sh's header shows the curl invocation that runs it")
}

/// The command the app's update card hands a person whose `kendex` command
/// sits where the app cannot write. They have no in-app remedy — that is
/// what the card's arm means — so a command that has drifted from the one
/// the script publishes leaves them with nothing that works, and `curl`
/// failing inside a pipe into `sh` still exits 0.
///
/// Read against the script itself, the way the `bindir` list above is, and
/// through the card rather than the constant behind it: an arm that stopped
/// offering the invocation would pass an equality check against that
/// constant and fail a person just as completely.
#[test]
#[allow(clippy::unwrap_used)]
fn the_card_offers_the_invocation_the_script_publishes() {
    let script = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../install.sh");
    let card = kendex_core::command_update::CommandNotice::for_card(
        &kendex_core::command_update::CommandBeside::NeedsPrivilege("/usr/local/bin/kendex".into()),
    );
    let Some(kendex_core::command_update::CommandNotice::NeedsPrivilege { command, .. }) = card
    else {
        panic!("the card owes a command kendex cannot write an installer, and offered {card:?}");
    };
    assert_eq!(
        published_invocation(&fs::read_to_string(&script).unwrap()),
        command,
        "install.sh publishes one invocation and the update card offers another"
    );
}

/// Where a re-run of `install.sh` lands, so the card can go on saying the
/// installer picks its own directory rather than naming one.
///
/// Two halves, and the name claims only what both together can see. Read:
/// the script's candidate list puts the home directory first. Run: with
/// `/usr/local/bin` ahead of the home directory on `PATH`, the command
/// still lands in the home directory, so `PATH` order does not decide.
///
/// What neither half can see is whether the home directory was taken
/// because it matched or because nothing did: `install.sh` falls back to
/// that same directory when no candidate is on `PATH` at all, so a run and
/// a fallback are one destination here. Separating them means a run that
/// lands in `/usr/local/bin`, which is a privileged write this suite will
/// not make. Hence the list is read rather than inferred.
#[test]
#[allow(clippy::unwrap_used)]
fn path_order_does_not_decide_where_a_re_run_lands() {
    let script = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../install.sh");
    let dirs = installer_bin_dirs(&fs::read_to_string(&script).unwrap());
    assert!(
        dirs.first().is_some_and(|first| first.starts_with("$HOME")),
        "install.sh tries {dirs:?} in that order; the home directory is no longer first"
    );
    // Without a second kind of candidate the order above is trivially
    // held and the run below settles nothing.
    assert!(
        dirs.iter().any(|dir| !dir.starts_with("$HOME")),
        "install.sh names only home candidates, so nothing here is about order: {dirs:?}"
    );

    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let (output, _) = run_install_in(HOST_UNAME, "x86_64", None, &home, &["/usr/local/bin"]);
    // Asked first, because it is the answer a drifted script gives: a run
    // that chose the system directory stops at the stub, and reading the
    // destination first would report only that it never said one.
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        !stderr.contains("tried to escalate") && !stderr.contains("outside its fixture"),
        "install.sh reached past the fixture: {stderr}"
    );
    let said = String::from_utf8_lossy(&output.stdout);
    let installed = said
        .lines()
        .find_map(|line| line.strip_prefix("Installed the kendex command to "))
        .unwrap_or_else(|| panic!("install.sh did not say where it installed:\n{said}"));
    assert_eq!(
        PathBuf::from(installed),
        home.join(".local/bin/kendex"),
        "install.sh chose {installed} with /usr/local/bin ahead of the home directory on PATH"
    );
}

/// The same contract from the other end, run rather than read: install.sh
/// performs a real install and says where it put the command, and that
/// directory is one the lookup would reach.
#[test]
#[allow(clippy::unwrap_used)]
fn where_a_real_install_puts_the_command_is_a_candidate() {
    let (output, _) = run_install("Linux", "x86_64", None);
    let said = String::from_utf8_lossy(&output.stdout);
    let installed = said
        .lines()
        .find_map(|line| line.strip_prefix("Installed the kendex command to "))
        .unwrap_or_else(|| panic!("install.sh did not say where it installed:\n{said}"));
    let home = PathBuf::from(installed)
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .to_owned();

    assert!(
        kendex_core::command_update::command_candidates(&home, None)
            .contains(&PathBuf::from(installed)),
        "install.sh installed {installed}, which no candidate under {} covers",
        home.display()
    );
}

/// The desktop app carries the command across only when an installer said
/// which file it is, so `install.sh` has to leave that record where the
/// app's own resolver looks, at the path it actually installed. A script
/// that installs and records nothing leaves every app-driven update
/// refusing a command it really does own.
///
/// Read back through the resolver rather than by hand: what shape the
/// record takes is core's to say, and a second spelling here agrees until
/// it does not.
#[test]
#[allow(clippy::unwrap_used)]
fn install_sh_records_the_command_it_installed() {
    let tmp = tempfile::tempdir().unwrap();
    // The canonical root, and the same one handed to the script: install.sh
    // writes under the HOME it was given, and a resolver asked about a
    // different spelling of that directory reads an empty one.
    let home = rooted(&tmp);
    let (output, _) = run_install_at(HOST_UNAME, "x86_64", &home);
    assert!(
        output.status.success(),
        "install.sh failed:\n{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let said = String::from_utf8_lossy(&output.stdout);
    let installed = said
        .lines()
        .find_map(|line| line.strip_prefix("Installed the kendex command to "))
        .unwrap_or_else(|| panic!("install.sh did not say where it installed:\n{said}"));

    // Asked of the resolver rather than spelled a second time: the data
    // directory differs by platform and a second spelling agrees until it
    // does not.
    let env = kendex_core::env::Env::host_rooted(&home);
    let recorded = kendex_core::command_update::recorded_command(&env).unwrap_or_else(|| {
        panic!(
            "install.sh recorded nothing this build can read at {}",
            env.installed_command_file().display()
        )
    });
    assert_eq!(recorded.path, PathBuf::from(installed));
}

/// A record the script cannot write costs the app-side update and never
/// the install: the run says so on stderr and carries on. The branch fires
/// on either write behind it failing — here the record path is a directory,
/// so `mkdir -p` finds the state directory already there and the redirect
/// has nowhere to land. A mode bit would have been the other spelling, and
/// a run acting as root writes through those.
#[test]
#[allow(clippy::unwrap_used)]
fn install_sh_says_when_it_cannot_record_the_command() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    // Asked of the resolver: the record path differs by platform, and a
    // second spelling here agrees until it does not.
    let env = kendex_core::env::Env::host_rooted(&home);
    fs::create_dir_all(env.installed_command_file()).unwrap();

    let (output, _) = run_install_at(HOST_UNAME, "x86_64", &home);
    let said = String::from_utf8_lossy(&output.stderr);

    assert!(
        output.status.success(),
        "a record that would not be written cost the install itself:\n{said}"
    );
    assert!(
        String::from_utf8_lossy(&output.stdout).contains("Installed the kendex command to"),
        "the command was never installed, so the record is not what this proves:\n{}",
        String::from_utf8_lossy(&output.stdout)
    );
    assert!(
        said.contains("could not record the command's identity"),
        "the run said nothing about the record it did not write:\n{said}"
    );
    assert_eq!(
        kendex_core::command_update::recorded_command(&env),
        None,
        "the app was handed a record install.sh never wrote"
    );
}
