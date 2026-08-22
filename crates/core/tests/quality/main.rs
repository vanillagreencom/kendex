//! The safety gate end to end: what a plan says about the content it would
//! write, what refuses to install, and what an override does and does not
//! buy.
#![cfg(unix)]

mod author_reviews;
mod author_reviews_binding;
mod author_reviews_emitted;
mod author_reviews_injection;
mod author_reviews_installations;
mod author_reviews_occurrence;
mod author_reviews_provenance;
mod author_reviews_records;
mod author_reviews_split;
mod author_reviews_untrusted;
mod convergence;
mod decisions;
mod decisions_lifecycle;
mod decisions_refuse;
mod fixture;
mod gate;
mod gate_rendered;
mod kinds;
mod overrides;
mod reading;
mod review_hash;
mod review_hash_entries;
mod rules;
mod rules_fetch;
mod rules_shapes;
mod scoring;
