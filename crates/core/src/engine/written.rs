//! Positions one planning pass has already planned a write for. Two
//! harnesses can read one physical tree — and, where a global root is
//! pointed at another tool's, one link — and planning the same write twice
//! fails the second op and rolls the whole apply back.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

#[derive(Default)]
pub(super) struct Written {
    pub(super) canonicals: BTreeSet<PathBuf>,
    links: BTreeSet<PathBuf>,
    /// What the item being planned right now claimed. A refusal is reached
    /// after the tree half has already claimed its position, and a claim
    /// left standing for an item that plans nothing would silently drop the
    /// next harness's install of the same tree.
    claimed: Vec<Claimed>,
}

enum Claimed {
    Canonical(PathBuf),
    Link(PathBuf),
}

impl Written {
    /// Start one item's pass. What it claims from here is undone together.
    pub(super) fn start_item(&mut self) {
        self.claimed.clear();
    }

    /// Take back everything the item just claimed — it plans nothing.
    pub(super) fn undo_item(&mut self) {
        for claimed in self.claimed.drain(..) {
            match claimed {
                Claimed::Canonical(path) => self.canonicals.remove(&path),
                Claimed::Link(path) => self.links.remove(&path),
            };
        }
    }

    /// Whether this pass is the one that claims the position.
    pub(super) fn claim_canonical(&mut self, path: &Path) -> bool {
        let first = self.canonicals.insert(path.to_path_buf());
        if first {
            self.claimed.push(Claimed::Canonical(path.to_path_buf()));
        }
        first
    }

    pub(super) fn claim_link(&mut self, path: &Path) -> bool {
        let first = self.links.insert(path.to_path_buf());
        if first {
            self.claimed.push(Claimed::Link(path.to_path_buf()));
        }
        first
    }
}
