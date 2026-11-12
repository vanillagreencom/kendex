use std::collections::BTreeMap;

use kendex_core::model::Scope;
use kendex_core::source_ops::SubscriptionRow;

use super::*;
use crate::ui::testing::{plain, rich, tagged};

fn subscription(name: &str, counted: Option<usize>, enabled: bool) -> SubscriptionRow {
    SubscriptionRow {
        scope: Scope::Global,
        name: name.to_owned(),
        repo: Some(format!("acme/{name}")),
        path: None,
        rev: Some("v2".to_owned()),
        commit: None,
        enabled,
        counts: counted.map(|count| BTreeMap::from([("skill".to_owned(), count)])),
    }
}

/// A subscription that was never downloaded says so rather than counting
/// zero, and one switched off says it after its count.
#[test]
fn marketplace_list_snapshots() {
    let cells: Vec<Vec<String>> = [
        subscription("tools", Some(3), true),
        subscription("old", None, false),
    ]
    .into_iter()
    .map(subscription_cells)
    .collect();
    assert_eq!(
        subscriptions(&plain(), &cells),
        [
            "global  tools  acme/tools @ v2  [3 package(s)]",
            "global  old  acme/old @ v2  [not downloaded yet]  (switched off)",
        ]
    );
    assert_eq!(
        tagged(&subscriptions(&rich(100), &cells)),
        [
            "",
            "<1;36>subscriptions</>  <90>2</>",
            "  <1;90>scope</>   <1;90>name</>   <1;90>from</>             <1;90>packages</>",
            "  <90>────────────────────────────────────────────────────────────────────</>",
            "  global  tools  acme/tools @ v2  [3 package(s)]",
            "  global  old    acme/old @ v2    [not downloaded yet] (switched off)",
        ]
    );
    assert!(subscriptions(&rich(80), &[]).is_empty());
}

/// The unsubscribe that landed, removed or kept.
#[test]
fn marketplace_unsubscribe_snapshots() {
    assert_eq!(
        unsubscribed(&plain(), &Scope::Global, "tools", 2, true),
        ["global: unsubscribed from 'tools', 2 kept"]
    );
    assert_eq!(
        tagged(&unsubscribed(&rich(80), &Scope::Global, "tools", 1, false)),
        ["  <32>✓</> global: unsubscribed from 'tools', 1 removed"]
    );
}
