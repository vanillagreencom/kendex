use std::collections::HashMap;

use chrono::{DateTime, Utc};

use crate::state::snapshot::{DashboardSnapshot, TrackedSession};

use super::claude::ClaudeSource;
use super::codex::CodexSource;
use super::opencode::OpenCodeSource;
use super::pi::PiSource;
use super::pricing::PricingTable;
use super::{CostMetrics, CostSource, SessionTotals};

const BLANK_AFTER_FAILURES: u8 = 10;

pub struct CostAggregator {
    sources: Vec<Box<dyn CostSource>>,
    cache: HashMap<String, CostMetrics>,
    failures: HashMap<String, u8>,
    last_errors: HashMap<String, String>,
    pricing_source: String,
}

impl Default for CostAggregator {
    fn default() -> Self {
        let pricing = PricingTable::load();
        let pricing_source = pricing.source_label.clone();
        Self::with_sources(
            vec![
                Box::new(ClaudeSource::new(pricing)) as Box<dyn CostSource>,
                Box::new(PiSource),
                Box::new(OpenCodeSource),
                Box::new(CodexSource),
            ],
            pricing_source,
        )
    }
}

impl CostAggregator {
    #[must_use]
    pub fn with_sources(sources: Vec<Box<dyn CostSource>>, pricing_source: String) -> Self {
        Self {
            sources,
            cache: HashMap::new(),
            failures: HashMap::new(),
            last_errors: HashMap::new(),
            pricing_source,
        }
    }

    pub fn poll_snapshot(
        &mut self,
        snapshot: &DashboardSnapshot,
        now: DateTime<Utc>,
    ) -> SessionTotals {
        let mut totals = SessionTotals {
            pricing_source: self.pricing_source.clone(),
            last_polled: Some(now),
            ..SessionTotals::default()
        };

        for entry in &snapshot.sessions {
            let metrics = self.poll_entry(entry);
            if metrics.source_error.is_some() {
                totals.unhealthy_sources = totals.unhealthy_sources.saturating_add(1);
            }
            add_to_totals(&mut totals, entry, metrics);
        }
        totals.grand.last_model = None;
        totals.grand.source_error = None;
        totals
    }

    fn poll_entry(&mut self, entry: &TrackedSession) -> CostMetrics {
        let Some(source) = self
            .sources
            .iter_mut()
            .find(|source| source.supports(entry))
        else {
            return CostMetrics::default().with_error("no cost source");
        };
        match source.poll(entry) {
            Ok(mut metrics) => {
                metrics.source_error = None;
                self.cache.insert(entry.id.clone(), metrics.clone());
                self.failures.remove(&entry.id);
                self.last_errors.remove(&entry.id);
                metrics
            }
            Err(error) => {
                let error = error.to_string();
                let failures = self.failures.entry(entry.id.clone()).or_insert(0);
                *failures = failures.saturating_add(1);
                let source_name = source.name();
                if self.last_errors.get(&entry.id) != Some(&error) {
                    tracing::warn!(entry = %entry.id, source = source_name, error = %error, "cost source failed");
                    self.last_errors.insert(entry.id.clone(), error.clone());
                }
                let mut metrics = if *failures >= BLANK_AFTER_FAILURES {
                    CostMetrics::default()
                } else {
                    self.cache.get(&entry.id).cloned().unwrap_or_default()
                };
                metrics.source_error = Some(error);
                metrics
            }
        }
    }
}

fn add_to_totals(totals: &mut SessionTotals, entry: &TrackedSession, metrics: CostMetrics) {
    totals.by_entry.insert(entry.id.clone(), metrics.clone());
    if metrics.source_error.is_none() {
        totals.grand.add_assign(&metrics);
        let harness = entry.harness.as_deref().unwrap_or("unknown").to_owned();
        let harness_total = totals.by_harness.entry(harness).or_default();
        harness_total.sessions = harness_total.sessions.saturating_add(1);
        harness_total.metrics.add_assign(&metrics);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::state::schema::{AdapterMetadata, LaunchInfo};
    use crate::state::snapshot::{SessionKind, SessionState, TrackedSession};

    struct FakeSource;

    impl CostSource for FakeSource {
        fn name(&self) -> &'static str {
            "fake"
        }

        fn supports(&self, _entry: &TrackedSession) -> bool {
            true
        }

        fn poll(
            &mut self,
            _entry: &TrackedSession,
        ) -> Result<CostMetrics, super::super::CostError> {
            Ok(CostMetrics {
                input_tokens: 100,
                output_tokens: 10,
                cost_usd: 0.01,
                turns: 2,
                ..CostMetrics::default()
            })
        }
    }

    #[test]
    fn aggregator_sums_grand_and_harness_totals() {
        let now = Utc::now();
        let mut snapshot = DashboardSnapshot::empty_for_session("s", "state.json".into(), now);
        snapshot.sessions = vec![session("a", "pi"), session("b", "claude")];
        let mut aggregator =
            CostAggregator::with_sources(vec![Box::new(FakeSource)], String::from("test pricing"));
        let totals = aggregator.poll_snapshot(&snapshot, now);
        assert_eq!(totals.grand.input_tokens, 200);
        assert_eq!(totals.grand.output_tokens, 20);
        assert_eq!(totals.grand.turns, 4);
        assert_eq!(totals.by_harness["pi"].sessions, 1);
        assert_eq!(totals.by_harness["claude"].metrics.cost_usd, 0.01);
    }

    fn session(id: &str, harness: &str) -> TrackedSession {
        TrackedSession {
            id: id.to_owned(),
            title: id.to_owned(),
            kind: SessionKind::Adhoc,
            state: SessionState::Ready,
            substate: None,
            harness: Some(harness.to_owned()),
            window: None,
            pane_target: None,
            pane_id: None,
            cwd: None,
            launch: LaunchInfo::default(),
            adapter: AdapterMetadata::default(),
            domain: None,
            last_response_at: None,
            spawned_at: None,
            last_polled_at: None,
            decisions_log: Vec::new(),
            stats: Default::default(),
            pr_number: None,
            worktree: None,
            branch: None,
        }
    }
}
