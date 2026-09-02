//! The shape a preview read answers with: one file's path, its bytes up to
//! the reader's cap, and whether the cap cut them. Built by
//! `package::detail::capped` and `package::item_file`, and returned
//! unchanged by every surface that previews a file.

use serde::{Deserialize, Serialize};
use specta::Type;

#[derive(Debug, Clone, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct ItemSource {
    pub path: String,
    pub content: String,
    pub truncated: bool,
}
