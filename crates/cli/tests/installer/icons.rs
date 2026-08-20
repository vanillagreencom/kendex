//! The icons the installer owes the desktop environment, and what it must
//! not take away when it cannot fetch one.

use std::io::Write;
use std::path::PathBuf;

use crate::{
    ICONS, Unlocked, desktop_entry, icon_slot, repo_root, run_installer, run_installer_over,
    run_installer_serving, running_as_root, set_mode,
};

/// A launcher filling a HiDPI slot from the 128px icon upscales it, and the
/// result looks soft beside every other app on the machine.
#[test]
fn every_icon_the_app_ships_lands_in_its_own_slot() {
    let tmp = run_installer();
    for (size, source) in ICONS {
        let installed = tmp
            .path()
            .join(format!("share/icons/hicolor/{size}/apps/kendex.png"));
        let installed = std::fs::read(&installed)
            .unwrap_or_else(|error| panic!("{size}: {} ({error})", installed.display()));
        let expected = std::fs::read(repo_root().join("crates/app/icons").join(source))
            .expect("the app ships this icon");
        assert_eq!(installed, expected, "the {size} slot must carry {source}");
    }
}

/// curl creates the output file before the transfer, so a fetch that fails
/// leaves an empty one behind — in the very slot a HiDPI launcher prefers,
/// where it would shadow the size that did install.
#[test]
fn an_icon_that_cannot_be_fetched_leaves_nothing_behind() {
    let nothing = tempfile::tempdir().expect("tempdir");
    let tmp = run_installer_serving(nothing.path());
    for (size, _) in ICONS {
        let slot = tmp
            .path()
            .join(format!("share/icons/hicolor/{size}/apps/kendex.png"));
        assert!(!slot.exists(), "{size}: {}", slot.display());
    }
}

/// This script is the upgrade path too, and the icon fetches go to a host
/// that rate-limits. Taking away the icon a previous run installed, because
/// this run could not fetch it, leaves the person worse off than not having
/// run the installer at all.
#[test]
fn a_fetch_that_fails_keeps_the_icon_an_earlier_run_installed() {
    let nothing = tempfile::tempdir().expect("tempdir");
    let earlier = b"an icon a previous run installed".as_slice();
    let tmp = run_installer_over(nothing.path(), |home| {
        for (size, _) in ICONS {
            let slot = icon_slot(home, size);
            std::fs::create_dir_all(slot.parent().expect("slot dir")).expect("slot");
            std::fs::write(&slot, earlier).expect("earlier icon");
        }
    });

    for (size, _) in ICONS {
        let slot = icon_slot(tmp.path(), size);
        assert_eq!(
            std::fs::read(&slot).expect("earlier icon"),
            earlier,
            "{size}"
        );
    }
}

/// Icons someone once installed under sudo: the file cannot be overwritten
/// and the directory cannot be written either, so neither replacing the icon
/// nor removing it can succeed. An icon is not worth failing an install over
/// — the app is already copied by then, and the launcher entry is not
/// written yet.
#[test]
fn icons_it_can_neither_replace_nor_remove_do_not_stop_the_install() {
    if running_as_root() {
        // The whole scenario is built out of permissions, and none of them
        // stop root: the icons would simply be replaced, and the failure
        // would say nothing about the behaviour under test.
        let _ = writeln!(
            std::io::stderr(),
            "installer: skipped as root — this case is made of permissions"
        );
        return;
    }

    let earlier = b"an icon a previous run installed".as_slice();
    let mut locked: Vec<PathBuf> = Vec::new();
    let tmp = run_installer_over(&repo_root(), |home| {
        for (size, _) in ICONS {
            let slot = icon_slot(home, size);
            let dir = slot.parent().expect("slot dir").to_path_buf();
            std::fs::create_dir_all(&dir).expect("slot");
            std::fs::write(&slot, earlier).expect("earlier icon");
            set_mode(&slot, 0o444);
            set_mode(&dir, 0o555);
            locked.push(dir);
        }
    });
    // Declared after `tmp`, so it hands the modes back before `TempDir`
    // tries to remove a tree it would otherwise not be allowed to.
    let _unlocked = Unlocked(locked);

    assert!(desktop_entry(&tmp).contains("StartupWMClass="));
    for (size, _) in ICONS {
        let slot = icon_slot(tmp.path(), size);
        assert_eq!(
            std::fs::read(&slot).expect("earlier icon"),
            earlier,
            "{size}"
        );
    }
}
