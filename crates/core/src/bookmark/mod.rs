//! Bookmarks: marketplace packages and curated sets a person saved to
//! find again, kept for this machine and belonging to no project.
//!
//! A bookmark is neither a copy of what it names nor a subscription to it.
//! It records an identity — which marketplace, what kind of thing, and the
//! name the catalog offers it under — and everything shown about it is read
//! back through the ordinary browse path at the moment it is shown. So a
//! package that gains a version, a set that gains a member, and a
//! marketplace that renames itself all read as they are, and saving one
//! installs nothing, subscribes to nothing and writes into no project.
//!
//! The index lives in its own `bookmarks.toml` beside the settings file,
//! written through the same one-writer-at-a-time discipline every other
//! machine-local preference goes through — see [`index`]. The template
//! index is its neighbour and keeps its own file for the same reason:
//! these are personal lists, not settings the Settings page writes back
//! whole.

use serde::{Deserialize, Serialize};
use specta::Type;

use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::model::ItemKind;

mod index;
mod resolve;

pub use resolve::{Reach, SavedItem, resolve};

/// What a bookmark points at inside a marketplace: one package the catalog
/// offers, of one kind, or a curated set the catalog declares and installs
/// whole.
///
/// The kind rides inside the package arm rather than beside it, so a set —
/// which has no package kind — cannot be recorded with one, and a package
/// cannot be recorded without one.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(
    tag = "is",
    rename_all = "kebab-case",
    rename_all_fields = "kebab-case"
)]
pub enum BookmarkItem {
    Package { kind: ItemKind },
    Bundle,
}

impl BookmarkItem {
    /// The package kind this is, or `None` for a curated set.
    pub fn kind(self) -> Option<ItemKind> {
        match self {
            BookmarkItem::Package { kind } => Some(kind),
            BookmarkItem::Bundle => None,
        }
    }

    /// What this is called in a line a person reads or types.
    pub fn name(self) -> &'static str {
        match self.kind() {
            Some(kind) => kind.name(),
            None => BUNDLE_WORD,
        }
    }

    /// Every word [`BookmarkItem::parse`] takes, in the order they are
    /// offered — derived from [`ItemKind::ALL`], so a kind added to the
    /// model is a kind this vocabulary gains rather than one it silently
    /// leaves out.
    pub fn words() -> Vec<&'static str> {
        ItemKind::ALL
            .iter()
            .map(|kind| kind.name())
            .chain(std::iter::once(BUNDLE_WORD))
            .collect()
    }

    /// One of those words read back, or the refusal listing them. The one
    /// place this vocabulary is parsed: `kendex bookmark` takes it on the
    /// command line and nothing else spells it.
    pub fn parse(word: &str) -> Result<BookmarkItem> {
        if word == BUNDLE_WORD {
            return Ok(BookmarkItem::Bundle);
        }
        ItemKind::ALL
            .iter()
            .find(|kind| kind.name() == word)
            .map(|kind| BookmarkItem::Package { kind: *kind })
            .ok_or_else(|| CoreError::BookmarkUnusable {
                what: word.to_owned(),
                why: format!("name one of {}", BookmarkItem::words().join(", ")),
            })
    }
}

/// The word a curated set is named by wherever this vocabulary is written
/// or read.
const BUNDLE_WORD: &str = "bundle";

/// One saved marketplace item.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "kebab-case")]
pub struct Bookmark {
    /// The marketplace, named the way a source declaration names it: the
    /// repository, or the folder a path source points at. Never the
    /// subscription's alias — an alias is a per-place manifest key, and a
    /// bookmark belongs to no place, so two projects spelling one
    /// marketplace differently would save as two different bookmarks.
    pub repo: String,
    pub item: BookmarkItem,
    /// The name the catalog offers it under.
    pub name: String,
}

impl Bookmark {
    /// What tells one bookmark from another: the marketplace folded to one
    /// string, what kind of thing it is, and its name.
    ///
    /// The repository goes through [`crate::source_ref::repo_identity`],
    /// this repository's one judge of whether two references name one
    /// marketplace — the same value subscription dedup, update grouping and
    /// template membership compare. A stored `repo` is a reference to
    /// browse with and a spelling to show, never a value to compare:
    /// `owner/repo` and its HTTPS spelling are one marketplace and two
    /// strings, so saving from a page that spells it one way and a row that
    /// spells it the other is one bookmark. Two marketplaces offering the
    /// same name stay two.
    pub fn identity(&self) -> (String, BookmarkItem, &str) {
        (
            crate::source_ref::repo_identity(&self.repo),
            self.item,
            self.name.as_str(),
        )
    }

    /// Whether these name the same saved item.
    pub fn is(&self, other: &Bookmark) -> bool {
        self.identity() == other.identity()
    }

    /// A bookmark this index may hold, or why not. Asked of what a person
    /// or a surface hands in, and again of every row read back off disk, so
    /// a hand-edited file cannot put a row on screen that names nothing.
    fn usable(&self) -> std::result::Result<(), String> {
        if self.name.trim().is_empty() {
            return Err("it has no name".to_owned());
        }
        if self.repo.trim().is_empty() {
            return Err("it names no marketplace".to_owned());
        }
        Ok(())
    }
}

/// Every bookmark on this machine, in the order they were saved.
pub fn list(env: &Env) -> Result<Vec<Bookmark>> {
    Ok(index::load(env)?.bookmarks)
}

/// Save one. Saving the same item again is the same one bookmark: the
/// index is keyed by identity, and a second row would be a second way to
/// remove one thing.
pub fn add(env: &Env, bookmark: Bookmark) -> Result<Bookmark> {
    if let Err(why) = bookmark.usable() {
        return Err(CoreError::BookmarkUnusable {
            what: bookmark.name.clone(),
            why,
        });
    }
    index::mutate(env, |index| {
        if !index.bookmarks.iter().any(|held| held.is(&bookmark)) {
            index.bookmarks.push(bookmark.clone());
        }
        Ok(bookmark)
    })
    .map(|(_, saved)| saved)
}

/// Take one out. Nothing installed from it is touched: a bookmark is a
/// note about where something came from, and removing the note removes the
/// note.
pub fn remove(env: &Env, bookmark: &Bookmark) -> Result<()> {
    index::mutate(env, |index| {
        let at = index
            .bookmarks
            .iter()
            .position(|held| held.is(bookmark))
            .ok_or_else(|| CoreError::NoSuchBookmark {
                name: bookmark.name.clone(),
            })?;
        index.bookmarks.remove(at);
        Ok(())
    })
    .map(|_| ())
}

#[cfg(test)]
mod tests;
