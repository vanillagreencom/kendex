//! The one harness kendex-core's integration tests build as: every file
//! beside this one is a module of it, so the crate and its dependencies link
//! once rather than once per file. Cargo's autodiscovery is off in
//! Cargo.toml, so a new file under `tests/` is a `mod` line here;
//! `tools/test-roster` holds that roster.
//!
//! A file that stays its own `[[test]]` target says why beside its
//! declaration in Cargo.toml.

#[path = "../../test_util.rs"]
mod test_util;

mod add_from_local;
mod adopt_many_tools;
mod adopt_pinned;
mod agent_aliases;
mod agent_skill_roots;
mod agent_skills_not_installed;
mod allowance;
mod antigravity;
mod app_update;
mod authored_summaries;
mod authoring;
mod authoring_check;
mod bot_instructions_refresh;
mod browse_unreadable_lock;
mod bundles;
mod byte_faithful;
mod catalog_compatibility;
mod catalog_links;
mod codex_mcp;
mod collections;
mod collision_refusal;
mod command_instructions;
mod command_names;
mod command_update_fetch;
mod commands;
mod copilot;
mod copilot_builtin;
mod copilot_reports;
mod credential_lock_process;
mod credential_transactions;
mod cursor_mcp;
mod custom_hooks;
mod dependencies;
mod discovery;
mod drift_check;
mod drift_hook_install;
mod drift_hook_script;
mod drift_worktree_remedy;
mod edits_and_forks;
mod emitted_paths;
mod env_detect;
mod fixture_manifest_paths;
mod gemini;
mod gemini_reports;
mod git_recorder;
mod guard_repo_paths;
mod guard_skill_roots;
mod guard_timeout_budget;
mod hook_promises;
mod hook_records;
mod hook_removal;
mod hook_sweep;
mod hooks_readme;
mod in_place_edits;
mod in_place_preservation;
mod install_into_project;
mod install_seam;
mod install_targets;
mod installs_nowhere;
mod instruction_shims;
mod invariants;
mod kinds;
mod lane;
mod left_out_by_own_line;
mod lock_from_another_project;
mod lock_record_branch;
mod marketplace_index;
mod marketplace_subscribe;
mod me_client;
mod migration;
mod model_classes;
mod not_offered_note;
mod opencode_commands;
mod opencode_mcp;
mod outdated_projects;
mod output_styles;
mod package_checks_plan;
mod package_detail;
mod package_diff;
mod package_identity;
mod package_pins;
mod package_versions;
mod permissions;
mod pi_carrier;
mod pi_commands;
mod pi_default_delegates;
mod plugin_registry;
mod plugin_targets;
mod process_guard_env;
mod project_hook_root;
mod quality;
mod refresh_stale;
mod registry;
mod repo_effects_leaving;
mod retired_items;
mod review_fixes;
mod scope_manifest_messages;
mod sealed_source;
mod secret_destination;
mod secret_storage;
mod settings_edits;
mod settings_grammar;
mod settings_seed;
mod settings_seed_repo;
mod shared_text;
mod skill_records;
mod source_record_floor;
mod source_store;
mod structural_claims;
mod submit_client;
mod surfaces;
mod symlinked_harness_dir;
mod transitions;
mod unmanaged_check;
mod unmanaged_ownership;
mod unmanaged_shapes;
mod unmanaged_takeover;
mod unsubscribe;
mod unsubscribe_keep;
mod v1_lock;
mod validate_output;

// The lane reads these transient wall spans from the existing REST job log.
// This stays local to each test binary; elapsed time does not identify CPU use.
mod diagnostic {
    use std::io::{self, Write};
    use std::thread::ThreadId;
    use std::time::Instant;

    pub(crate) struct Span {
        label: &'static str,
        started: Instant,
    }

    #[derive(Clone, Copy)]
    enum Phase {
        Begin,
        End(u128),
        Unwind(u128),
    }

    // Holding stderr for one record prevents our concurrent writers from
    // interleaving fields. Print macros would hide passing tests in capture.
    fn emit(
        writer: &mut impl Write,
        label: &'static str,
        phase: Phase,
        pid: u32,
        thread: ThreadId,
    ) -> io::Result<()> {
        match phase {
            Phase::Begin => writeln!(
                writer,
                "KEN4527 begin label={label} pid={pid} thread={thread:?}"
            ),
            Phase::End(ns) => writeln!(
                writer,
                "KEN4527 end label={label} pid={pid} thread={thread:?} elapsed_ns={ns}"
            ),
            Phase::Unwind(ns) => writeln!(
                writer,
                "KEN4527 unwind label={label} pid={pid} thread={thread:?} elapsed_ns={ns}"
            ),
        }
    }

    impl Span {
        fn write(&self, phase: Phase) -> io::Result<()> {
            emit(
                &mut io::stderr().lock(),
                self.label,
                phase,
                std::process::id(),
                std::thread::current().id(),
            )
        }

        fn try_begin(label: &'static str) -> io::Result<Self> {
            let started = Instant::now();
            emit(
                &mut io::stderr().lock(),
                label,
                Phase::Begin,
                std::process::id(),
                std::thread::current().id(),
            )?;
            Ok(Self { label, started })
        }

        pub(crate) fn begin(label: &'static str) -> Self {
            match Self::try_begin(label) {
                Ok(span) => span,
                Err(_) => panic!("KEN4527 write_failed phase=begin"),
            }
        }
    }

    impl Drop for Span {
        fn drop(&mut self) {
            let elapsed = self.started.elapsed().as_nanos();
            if std::thread::panicking() {
                // Preserve the original failure. An unwind or absent end is
                // incomplete evidence, even when the best-effort write works.
                let _ = self.write(Phase::Unwind(elapsed));
            } else if self.write(Phase::End(elapsed)).is_err() {
                panic!("KEN4527 write_failed phase=end");
            }
        }
    }

    #[test]
    fn diagnostic_contract() {
        // The compiled-head control log must expose this pair with libtest
        // capture enabled, before the lane reads native timings.
        let _diagnostic = Span::begin(concat!(module_path!(), "::diagnostic_contract"));
        // The lane's REST-log reader consumes this exact machine protocol.
        // These fake ids and durations are neither measurements nor children.
        let thread = std::thread::current().id();
        let mut output = Vec::new();
        for phase in [Phase::Begin, Phase::End(23), Phase::Unwind(29)] {
            assert!(emit(&mut output, "control", phase, 17, thread).is_ok());
        }
        let text = String::from_utf8(output).unwrap_or_else(|_| panic!("record is not UTF-8"));
        let expected = format!(
            "KEN4527 begin label=control pid=17 thread={thread:?}\nKEN4527 end label=control pid=17 thread={thread:?} elapsed_ns=23\nKEN4527 unwind label=control pid=17 thread={thread:?} elapsed_ns=29\n"
        );
        assert_eq!(text, expected);
        let mut other = Vec::new();
        assert!(emit(&mut other, "control", Phase::Begin, 19, thread).is_ok());
        assert_ne!(
            other,
            format!("{}\n", text.lines().next().unwrap_or_default()).as_bytes()
        );
        assert!(String::from_utf8_lossy(&other).contains(" pid=19 "));

        struct FailedWriter {
            remaining: usize,
            written: Vec<u8>,
        }
        impl Write for FailedWriter {
            fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
                if self.remaining == 0 {
                    return Err(io::ErrorKind::BrokenPipe.into());
                }
                let count = bytes.len().min(self.remaining);
                self.written.extend_from_slice(&bytes[..count]);
                self.remaining -= count;
                Ok(count)
            }
            fn flush(&mut self) -> io::Result<()> {
                Ok(())
            }
        }
        // A real stderr sink can fail before or during any record. A partial
        // record never reaches a successful emitter result or a complete line.
        for phase in [Phase::Begin, Phase::End(23), Phase::Unwind(29)] {
            for remaining in [0, 7] {
                let mut writer = FailedWriter {
                    remaining,
                    written: Vec::new(),
                };
                let result = emit(&mut writer, "control", phase, 17, thread);
                assert_eq!(
                    result.err().map(|error| error.kind()),
                    Some(io::ErrorKind::BrokenPipe)
                );
                assert!(!writer.written.ends_with(b"\n"));
            }
        }
    }
}
