//! The safety rules end to end: what a plan says about the content it
//! would write, what the audit reads back, and the advisory score both
//! report.
#![cfg(unix)]

#[path = "../../../test_util.rs"]
mod test_util;

mod advisory;
mod corpus;
mod fixture;
mod kinds;
mod reading;
mod rules;
mod rules_blocks;
mod rules_fetch;
mod rules_shapes;
mod scoring;
