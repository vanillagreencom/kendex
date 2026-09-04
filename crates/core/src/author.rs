//! Authoring a marketplace: the Mine rows, the scaffold, the import, and
//! the local-readiness status behind them.
//!
//! The rules this module holds itself to (§3.6, pass 3): "use existing"
//! writes zero bytes inside the folder it reads; the scaffold is
//! byte-stable — identical inputs produce identical trees; imports name
//! their byte origin and never copy marketplace content past an unknown
//! licence without an explicit basis; and readiness here is local only —
//! whether the world can see the repository is the registry client's
//! authenticated question, never guessed from here.

pub mod import;
pub mod preflight;
pub mod registry;
pub mod scaffold;
pub mod status;

pub use import::{ImportCandidate, ImportOutcome, ImportSelection, apply, inventory};
pub use preflight::{PreflightCheck, SubmitPreflight, submit_preflight};
pub use registry::{list, register, unregister};
pub use scaffold::{CreateRequest, License, create, plan};
pub use status::{GitReadiness, MineRow, status, use_existing};
