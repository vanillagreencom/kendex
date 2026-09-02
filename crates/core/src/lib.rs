// `crates/test_util.rs` is one file `#[path]`-included by the test binaries
// of all three crates, so it has one spelling for the core crate and that
// spelling is the external one. This alias makes it resolve here too, where
// the crate is otherwise only `crate`. Test-only on purpose: production code
// inside core says `crate::`, and an alias that does not exist there cannot
// become a second spelling for it.
#[cfg(test)]
extern crate self as kendex_core;

// Declared once for the whole lib test tree. Four `#[cfg(test)]` modules used
// to `#[path]`-include the file separately, which is one module compiled four
// times under four names; every `use` of it now names this one.
#[cfg(test)]
#[path = "../../test_util.rs"]
mod test_util;

pub mod app_update;
pub mod apply;
pub mod author;
pub mod base;
pub(crate) mod capture;
pub mod check_catalog;
pub mod clock;
pub mod command_update;
pub mod configedit;
pub mod discover;
pub mod drift;
pub mod engine;
pub mod env;
pub mod error;
pub mod frontmatter;
pub mod fs;
pub mod guard;
pub mod harness;
pub mod hash;
pub mod hook;
pub mod install_channel;
pub mod library;
pub mod lock;
pub mod manifest;
pub mod mapping;
pub mod model;
pub mod names;
pub mod package;
pub mod parallel;
pub mod paths;
pub mod pi_ext;
pub mod process;
pub mod quality;
pub mod registry;
pub mod release_digests;
pub mod remote;
pub mod render;
pub mod repo_effects;
pub mod report;
pub mod scan;
pub mod settings;
pub mod settings_file;
pub mod settings_seed;
pub mod settings_template;
pub mod settings_toml;
pub mod settings_view;
pub mod source;
pub mod source_ops;
pub mod source_read;
pub mod source_ref;
pub mod tags;
pub mod update_channel;
pub mod update_feed;
pub mod vendor;
