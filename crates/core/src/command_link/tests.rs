// Symlinks and the privileged step's shell are Unix; the step itself only
// ever runs on macOS.
#![cfg(unix)]

use std::cell::Cell;
use std::os::unix::fs::{PermissionsExt, symlink};
use std::path::{Path, PathBuf};

use super::*;
use crate::env::FakeOs;
use crate::test_util::rooted;

/// A Mac in a temporary tree: this app's bundle, an older copy's bundle,
/// the three places a command is searched for, and the link. Nothing is
/// created in any of them until a row plants it.
struct Mac {
    root: PathBuf,
    places: Places,
    /// The running app's executable.
    app: PathBuf,
    /// The command this app carries.
    target: PathBuf,
    /// The command an older copy of kendex carries, its bundle name holding
    /// a space the way a Finder duplicate's does.
    older: PathBuf,
}

impl Mac {
    fn new(tmp: &tempfile::TempDir) -> Mac {
        let root = rooted(tmp);
        let macos = root.join("Applications/kendex.app/Contents/MacOS");
        std::fs::create_dir_all(&macos).unwrap();
        let app = macos.join("kendex-app");
        command(&app);
        let target = macos.join("kendex");
        command(&target);
        let link = root.join("usr/local/bin/kendex");
        Mac {
            places: Places {
                searched: vec![
                    link.clone(),
                    root.join("opt/homebrew/bin/kendex"),
                    root.join("home/.local/bin/kendex"),
                ],
                link,
            },
            older: root.join("Downloads/kendex 2.app/Contents/MacOS/kendex"),
            root,
            app,
            target,
        }
    }

    fn link_to(&self, to: &Path) {
        std::fs::create_dir_all(self.places.link.parent().unwrap()).unwrap();
        symlink(to, &self.places.link).unwrap();
    }

    fn state(&self, app: &Path, prompt: CommandLinkPrompt) -> CommandLinkState {
        state(Some(app), &self.places, prompt).unwrap()
    }
}

/// An executable file at `path`, its directory created.
fn command(path: &Path) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, b"#!/bin/sh\n").unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
}

/// A file that is not a command, at `path`.
fn data(path: &Path) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, b"not kendex").unwrap();
}

/// The real [`LINK_SCRIPT`], run by `/bin/sh` without the administrator
/// prompt, which is the one part a suite cannot drive. Counts its runs.
#[derive(Default)]
struct Unprivileged {
    runs: Cell<u32>,
}

impl Unprivileged {
    fn run(plan: &LinkPlan) -> Elevated {
        let args: Vec<String> = plan
            .script_args()
            .into_iter()
            .map(|arg| arg.into_string().unwrap())
            .collect();
        let mut argv = vec!["-c"];
        argv.extend(args.iter().map(String::as_str));
        // The script names every program by its absolute path; the two
        // variables are set so nothing inherited decides how it reads.
        let output = Hardened::program("/bin/sh", &argv)
            .env("PATH", "/usr/bin:/bin")
            .env("LC_ALL", "C")
            .run()
            .unwrap();
        match output.status.code() {
            Some(0) => Elevated::Done,
            Some(MOVED_EXIT) => Elevated::Moved,
            other => Elevated::Failed(format!(
                "status {other:?}: {}",
                String::from_utf8_lossy(&output.stderr)
            )),
        }
    }
}

impl Elevate for Unprivileged {
    fn link(&self, plan: &LinkPlan) -> Elevated {
        self.runs.set(self.runs.get() + 1);
        Unprivileged::run(plan)
    }
}

/// Every shape the link and the searched places can hold, and what the
/// first launch and the Settings row read off each. The rows the owner's
/// rules name: a command already reachable anywhere searched asks nothing;
/// a file that is not a link into a kendex app is left alone; a link into
/// an older copy is offered for repointing; a build carrying no command
/// asks nothing; and an answered question is not put again.
#[test]
#[allow(
    clippy::too_many_lines,
    reason = "one row per shape, in one visible list"
)]
fn the_judge_over_every_shape_the_places_can_hold() {
    type Plant = fn(&Mac);
    type Expect = fn(&Mac) -> CommandLink;
    let offered: Expect = |mac| CommandLink::Offered {
        link: mac.places.link.clone(),
        target: mac.target.clone(),
        replaces: None,
    };
    let repoint: Expect = |mac| CommandLink::Offered {
        link: mac.places.link.clone(),
        target: mac.target.clone(),
        replaces: Some(mac.older.clone()),
    };
    let taken: Expect = |mac| CommandLink::Taken {
        link: mac.places.link.clone(),
    };
    let at_link: Expect = |mac| CommandLink::Elsewhere {
        path: mac.places.link.clone(),
    };
    let rows: [(&str, Plant, CommandLinkPrompt, Expect, bool); 14] = [
        (
            "nothing installed asks",
            |_| {},
            CommandLinkPrompt::Ask,
            offered,
            true,
        ),
        (
            "an answered question is not put again",
            |_| {},
            CommandLinkPrompt::Answered,
            offered,
            false,
        ),
        (
            "a Homebrew command asks nothing",
            |mac| command(&mac.places.searched[1]),
            CommandLinkPrompt::Ask,
            |mac| CommandLink::Elsewhere {
                path: mac.places.searched[1].clone(),
            },
            false,
        ),
        (
            "a ~/.local/bin command asks nothing",
            |mac| command(&mac.places.searched[2]),
            CommandLinkPrompt::Ask,
            |mac| CommandLink::Elsewhere {
                path: mac.places.searched[2].clone(),
            },
            false,
        ),
        (
            "an install.sh copy at the link asks nothing",
            |mac| command(&mac.places.link),
            CommandLinkPrompt::Ask,
            at_link,
            false,
        ),
        (
            "a link to a live command outside any app asks nothing",
            |mac| {
                let cargo = mac.root.join("home/.cargo/bin/kendex");
                command(&cargo);
                mac.link_to(&cargo);
            },
            CommandLinkPrompt::Ask,
            at_link,
            false,
        ),
        (
            "the link to this app is installed",
            |mac| mac.link_to(&mac.target),
            CommandLinkPrompt::Ask,
            |mac| CommandLink::Linked {
                link: mac.places.link.clone(),
                target: mac.target.clone(),
            },
            false,
        ),
        (
            "a link to an older copy still there is offered, not asked",
            |mac| {
                command(&mac.older);
                mac.link_to(&mac.older);
            },
            CommandLinkPrompt::Ask,
            repoint,
            false,
        ),
        (
            "a link to an older copy since deleted is asked about",
            |mac| mac.link_to(&mac.older),
            CommandLinkPrompt::Ask,
            repoint,
            true,
        ),
        (
            "a file that is not a command at the link is left alone",
            |mac| data(&mac.places.link),
            CommandLinkPrompt::Ask,
            taken,
            false,
        ),
        (
            "a dangling link outside any app is left alone",
            |mac| mac.link_to(&mac.root.join("gone/kendex")),
            CommandLinkPrompt::Ask,
            taken,
            false,
        ),
        (
            "a link into an app to something not named kendex is left alone",
            |mac| mac.link_to(&mac.root.join("Applications/Other.app/Contents/MacOS/other")),
            CommandLinkPrompt::Ask,
            taken,
            false,
        ),
        (
            "a bundle without the command asks nothing",
            |mac| std::fs::remove_file(&mac.target).unwrap(),
            CommandLinkPrompt::Ask,
            |_| CommandLink::NotCarried,
            false,
        ),
        (
            "a directory at the link is left alone",
            |mac| std::fs::create_dir_all(&mac.places.link).unwrap(),
            CommandLinkPrompt::Ask,
            taken,
            false,
        ),
    ];
    for (name, plant, prompt, expect, ask) in rows {
        let tmp = tempfile::tempdir().unwrap();
        let mac = Mac::new(&tmp);
        plant(&mac);
        let got = mac.state(&mac.app, prompt);
        assert_eq!(
            got,
            CommandLinkState {
                command: expect(&mac),
                ask
            },
            "{name}"
        );
    }
}

/// What the running executable decides before any place is read: a build
/// that is not a bundle, a translocated copy, and another platform ask
/// nothing and offer nothing.
#[test]
fn the_running_executable_decides_whether_anything_is_offered() {
    let tmp = tempfile::tempdir().unwrap();
    let mac = Mac::new(&tmp);
    // `cargo build` puts the command beside the app's binary.
    let exe = mac.root.join("target/debug/kendex-app");
    command(&exe);
    command(&mac.root.join("target/debug/kendex"));
    assert_eq!(
        mac.state(&exe, CommandLinkPrompt::Ask),
        CommandLinkState {
            command: CommandLink::NotCarried,
            ask: false
        },
        "a build that is not a bundle asks nothing, a command beside it or not"
    );
    let translocated = mac
        .root
        .join("private/var/folders/T/AppTranslocation/0A1B/d/kendex.app/Contents/MacOS");
    command(&translocated.join("kendex"));
    assert_eq!(
        mac.state(&translocated.join("kendex-app"), CommandLinkPrompt::Ask),
        CommandLinkState {
            command: CommandLink::Translocated,
            ask: false
        },
        "a translocated copy asks nothing"
    );
    assert_eq!(
        state(None, &mac.places, CommandLinkPrompt::Ask).unwrap(),
        CommandLinkState {
            command: CommandLink::NotCarried,
            ask: false
        },
        "another platform asks nothing"
    );
}

/// What an install does over each shape, through the real privileged
/// script: where the step runs, and what is at the link afterwards.
#[test]
fn an_install_writes_only_where_the_judge_offered() {
    enum After {
        /// The link leads to this app's command, written as its path.
        LinkedHere,
        /// The file planted at the link still holds its bytes.
        Untouched,
    }
    type Plant = fn(&Mac);
    type Refusal = fn(&Mac) -> LinkRefused;
    type Row = (
        &'static str,
        Plant,
        std::result::Result<(), Refusal>,
        u32,
        After,
    );
    let rows: [Row; 5] = [
        (
            "creates the link, and the directory it sits in",
            |_| {},
            Ok(()),
            1,
            After::LinkedHere,
        ),
        (
            "repoints a link from an older copy",
            |mac| {
                command(&mac.older);
                mac.link_to(&mac.older);
            },
            Ok(()),
            1,
            After::LinkedHere,
        ),
        (
            "an installed link needs no step",
            |mac| mac.link_to(&mac.target),
            Ok(()),
            0,
            After::LinkedHere,
        ),
        (
            "refuses a foreign file without running the step",
            |mac| data(&mac.places.link),
            Err(|mac| LinkRefused::NotOffered {
                command: CommandLink::Taken {
                    link: mac.places.link.clone(),
                },
            }),
            0,
            After::Untouched,
        ),
        (
            "refuses when a command is already installed",
            |mac| command(&mac.places.link),
            Err(|mac| LinkRefused::NotOffered {
                command: CommandLink::Elsewhere {
                    path: mac.places.link.clone(),
                },
            }),
            0,
            After::Untouched,
        ),
    ];
    for (name, plant, expect, runs, after) in rows {
        let tmp = tempfile::tempdir().unwrap();
        let mac = Mac::new(&tmp);
        plant(&mac);
        let planted = std::fs::read(&mac.places.link).ok();
        let step = Unprivileged::default();
        let got = install(Some(&mac.app), &mac.places, &step);
        assert_eq!(got, expect.map_err(|refusal| refusal(&mac)), "{name}");
        assert_eq!(step.runs.get(), runs, "{name}: step runs");
        match after {
            After::LinkedHere => assert_eq!(
                Host.resolve(&mac.places.link),
                mac.target,
                "{name}: link leads here"
            ),
            After::Untouched => assert_eq!(
                std::fs::read(&mac.places.link).ok(),
                planted,
                "{name}: planted file"
            ),
        }
    }
}

/// The step runs as root, after a dialog a person may leave open, so it
/// holds the judge's answer itself: whatever reaches the link between the
/// judging and the step is left alone, and the install says what is there
/// now rather than that it succeeded.
#[test]
fn the_privileged_step_leaves_what_arrived_after_the_judging() {
    type Arrive = fn(&Mac);
    let rows: [(&str, Arrive, Arrive); 2] = [
        (
            "a file lands on an empty link",
            |_| {},
            |mac| data(&mac.places.link),
        ),
        (
            "an older copy's link is swapped for a foreign one",
            |mac| mac.link_to(&mac.older),
            |mac| {
                std::fs::remove_file(&mac.places.link).unwrap();
                mac.link_to(&mac.root.join("elsewhere/kendex"));
            },
        ),
    ];
    for (name, plant, arrive) in rows {
        let tmp = tempfile::tempdir().unwrap();
        let mac = Mac::new(&tmp);
        plant(&mac);

        struct Late<'a> {
            mac: &'a Mac,
            arrive: Arrive,
        }
        impl Elevate for Late<'_> {
            fn link(&self, plan: &LinkPlan) -> Elevated {
                (self.arrive)(self.mac);
                Unprivileged::run(plan)
            }
        }

        let got = install(Some(&mac.app), &mac.places, &Late { mac: &mac, arrive });
        assert_eq!(
            got,
            Err(LinkRefused::NotOffered {
                command: CommandLink::Taken {
                    link: mac.places.link.clone()
                }
            }),
            "{name}"
        );
        assert_ne!(
            Host.resolve(&mac.places.link),
            mac.target,
            "{name}: the arrival was replaced"
        );
    }
}

/// A dismissed prompt is its own answer and writes nothing.
#[test]
fn a_cancelled_prompt_changes_nothing() {
    struct Dismissed;
    impl Elevate for Dismissed {
        fn link(&self, _: &LinkPlan) -> Elevated {
            Elevated::Cancelled
        }
    }
    let tmp = tempfile::tempdir().unwrap();
    let mac = Mac::new(&tmp);
    assert_eq!(
        install(Some(&mac.app), &mac.places, &Dismissed),
        Err(LinkRefused::Cancelled)
    );
    assert!(crate::fs::entry(&mac.places.link).unwrap().is_none());
}

/// What `osascript` prints for each ending, as macOS prints it.
#[test]
fn osascript_endings_are_read_by_their_number() {
    let rows: [(&str, Elevated); 5] = [
        (
            "0:329: execution error: User canceled. (-128)\n",
            Elevated::Cancelled,
        ),
        (
            "0:329: execution error: The command exited with a non-zero status. (3)\n",
            Elevated::Moved,
        ),
        (
            "0:329: execution error: mkdir: /usr/local/bin: Read-only file system (1)\n",
            Elevated::Failed(
                "0:329: execution error: mkdir: /usr/local/bin: Read-only file system (1)"
                    .to_owned(),
            ),
        ),
        (
            "osascript: no such file (3a)",
            Elevated::Failed("osascript: no such file (3a)".to_owned()),
        ),
        (
            "  \n",
            Elevated::Failed("the administrator step failed and said nothing".to_owned()),
        ),
    ];
    for (stderr, expected) in rows {
        assert_eq!(from_osascript(stderr), expected, "{stderr:?}");
    }
}

/// Answering the question once is recorded, and the next launch reads the
/// record and does not ask.
#[test]
fn the_first_launch_question_is_put_once() {
    let tmp = tempfile::tempdir().unwrap();
    let mac = Mac::new(&tmp);
    let env = Env::fake(mac.root.join("home"), FakeOs::Linux);
    let asks = |env: &Env| {
        let prompt = settings::load(env).unwrap().command_link_prompt;
        state(Some(&mac.app), &mac.places, prompt).unwrap().ask
    };

    assert!(asks(&env), "a fresh machine asks");
    answer_prompt(&env).unwrap();
    assert_eq!(
        settings::load(&env).unwrap().command_link_prompt,
        CommandLinkPrompt::Answered
    );
    assert!(!asks(&env), "an answered machine does not ask again");
}

/// The link goes in `/usr/local/bin`, which exists or is created, and is
/// searched with Homebrew's and the home directory's; Homebrew's is never
/// the link.
#[test]
fn a_mac_links_in_usr_local_bin_and_searches_three_places() {
    let places = Places::on_this_mac(Path::new("/Users/someone"));
    assert_eq!(
        places,
        Places {
            link: PathBuf::from("/usr/local/bin/kendex"),
            searched: vec![
                PathBuf::from("/usr/local/bin/kendex"),
                PathBuf::from("/opt/homebrew/bin/kendex"),
                PathBuf::from("/Users/someone/.local/bin/kendex"),
            ],
        }
    );
}
