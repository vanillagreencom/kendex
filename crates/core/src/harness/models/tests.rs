use super::evidence::*;
use super::*;

fn context(provider: &str, ids: &[&str]) -> RuntimeContext {
    RuntimeContext {
        protocol: PROTOCOL.into(),
        harness: HarnessId::Pi,
        account: "fixture-account".into(),
        host: "fixture-host".into(),
        providers: vec![provider.into()],
        current_provider: Some(provider.into()),
        models: ModelListEvidence::Complete {
            source: "fixture:list".into(),
            account: "fixture-account".into(),
            host: "fixture-host".into(),
            models: ids
                .iter()
                .map(|id| AvailableModel {
                    provider: provider.into(),
                    id: (*id).into(),
                    native_selector: None,
                    allowed: true,
                    chat: true,
                    is_default: false,
                })
                .collect(),
        },
        default: HarnessModelPath::NativeDefault,
        capacity: ids
            .iter()
            .map(|id| ModelCapacityEvidence::Known {
                selector: format!("{provider}/{id}"),
                account: "fixture-account".into(),
                host: "fixture-host".into(),
                source: "fixture:capacity".into(),
                context_window: Some(1234),
            })
            .collect(),
        rejected: vec![],
        selector_observation: None,
    }
}
fn resolve(value: &str, context: &RuntimeContext) -> ModelResolution {
    resolve_model(
        &ModelRequest::parse(value).unwrap(),
        ResolutionContext::Runtime(context),
        &BTreeMap::new(),
    )
}
fn selected(result: ModelResolution) -> Selection {
    match result {
        ModelResolution::Selected { selection, .. } => selection,
        other => panic!("not selected: {other:?}"),
    }
}
#[test]
fn classes_aliases_and_finite_walk() {
    for (name, old, expected) in [
        ("top", "fable", ModelClass::Top),
        ("standard", "opus", ModelClass::Standard),
        ("light", "sonnet", ModelClass::Light),
        ("fast", "haiku", ModelClass::Fast),
    ] {
        assert_eq!(ModelClass::parse(name), Some(expected));
        assert_eq!(ModelClass::parse(old), Some(expected));
        let walk: Vec<_> = expected.walk().collect();
        assert_eq!(walk.len(), 4);
        for class in [
            ModelClass::Top,
            ModelClass::Standard,
            ModelClass::Light,
            ModelClass::Fast,
        ] {
            assert_eq!(walk.iter().filter(|c| **c == class).count(), 1);
        }
    }
    assert_eq!(
        ModelClass::Light.walk().collect::<Vec<_>>(),
        vec![
            ModelClass::Light,
            ModelClass::Fast,
            ModelClass::Standard,
            ModelClass::Top
        ]
    );
}
#[test]
fn native_root_selector_comparison_uses_observed_identity() {
    let mut context = context("anthropic", &[]);
    context.harness = HarnessId::Claude;
    assert_eq!(context.selector_change(), None);
    for (prior, current, expected) in [
        (None, "claude-opus-5-5", SelectorChange::Unknown),
        (Some("opus"), "claude-opus-5-5", SelectorChange::Equivalent),
        (
            Some("anthropic/opus"),
            "claude-opus-5-5",
            SelectorChange::Equivalent,
        ),
        (Some("claude-opus-5-5"), "opus", SelectorChange::Equivalent),
        (
            Some("claude-opus-5-5"),
            "anthropic/claude-opus-5-5",
            SelectorChange::Equivalent,
        ),
        (
            Some("claude-opus-5-5"),
            "claude-opus-5-5",
            SelectorChange::Equivalent,
        ),
        (Some("opus"), "claude-sonnet-5", SelectorChange::Changed),
        (
            Some("opus"),
            "claude-opus-5-preview",
            SelectorChange::Changed,
        ),
        (
            Some("opus"),
            "other/claude-opus-5-5",
            SelectorChange::Changed,
        ),
        (
            Some("claude-opus-5-5"),
            "claude-opus-5-6",
            SelectorChange::Changed,
        ),
        (Some("standard"), "claude-opus-5-5", SelectorChange::Changed),
    ] {
        context.selector_observation = Some(SelectorObservation {
            prior_selector: prior.map(str::to_owned),
            current_selector: current.into(),
        });
        assert_eq!(
            context.selector_change(),
            Some(expected),
            "{prior:?} {current}"
        );
    }
    context.harness = HarnessId::Pi;
    context.selector_observation = Some(SelectorObservation {
        prior_selector: Some("opus".into()),
        current_selector: "claude-opus-5-5".into(),
    });
    assert_eq!(context.selector_change(), Some(SelectorChange::Changed));
}
#[test]
fn request_kinds_and_override_rule() {
    assert_eq!(
        ModelRequest::parse("parent").unwrap(),
        ModelRequest::Inherit
    );
    assert!(matches!(
        ModelRequest::parse("anthropic/opus").unwrap(),
        ModelRequest::NativeFamily { .. }
    ));
    assert!(matches!(
        ModelRequest::parse("provider/custom").unwrap(),
        ModelRequest::Exact { .. }
    ));
    assert_eq!(
        ModelRequest::parse("openrouter/anthropic/claude-sonnet-4").unwrap(),
        ModelRequest::Exact {
            selector: "openrouter/anthropic/claude-sonnet-4".into()
        }
    );
    for value in ["", "a b", "a/", "/b", "a/b\u{0007}", "a/b c"] {
        assert!(ModelRequest::parse(value).is_err(), "{value}");
    }
    for (key, value, valid) in [
        ("fast", "provider/custom", true),
        ("light", "anthropic/sonnet", true),
        ("light", "openrouter/anthropic/claude-sonnet-4", true),
        ("top", "standard", false),
        ("fast", "inherit", false),
        ("other", "provider/custom", false),
        ("fast", "anthropic/claude-haiku-4-5", false),
        ("fast", "anthropic/claude-3-haiku-20240307", false),
        ("fast", "anthropic/claude-3-5-haiku-20241022", false),
        ("fast", "bare", false),
    ] {
        assert_eq!(
            validate_override(key, value).is_ok(),
            valid,
            "{key}={value}"
        );
    }
}
#[test]
fn confirmed_singletons_stay_in_provider_and_fast_claude_falls_back() {
    for (provider, id, effective) in [
        ("anthropic", "claude-sonnet-5", Some(ModelClass::Light)),
        ("openai", "gpt-6.1-terra", Some(ModelClass::Fast)),
        ("github-copilot", "gpt-6.1-sol", Some(ModelClass::Standard)),
        ("custom", "private-chat", None),
    ] {
        let context = context(provider, &[id]);
        for requested in ["top", "standard", "light", "fast"] {
            let selection = selected(resolve(requested, &context));
            assert_eq!(selection.provider, provider);
            assert_eq!(selection.concrete_id.as_deref(), Some(id));
            assert_eq!(selection.effective_class, effective);
        }
    }
    let context = context(
        "anthropic",
        &["claude-haiku-4-5", "claude-haiku-9", "claude-sonnet-5"],
    );
    let result = resolve("fast", &context);
    assert!(result.diagnostics().iter().any(|d| d.code == "fallback"));
    assert_eq!(
        selected(result).concrete_id.as_deref(),
        Some("claude-sonnet-5")
    );
}
#[test]
fn newest_family_numeric_snapshot_and_suffix_rules() {
    for (ids, expected) in [
        (
            vec!["gpt-6.9-sol", "gpt-6.10-sol", "gpt-99-sol-preview"],
            "gpt-6.10-sol",
        ),
        (
            vec![
                "gpt-6.1-sol-2026-01-01",
                "gpt-6.1-sol",
                "gpt-6.1-sol-20260201",
            ],
            "gpt-6.1-sol",
        ),
        (
            vec![
                "gpt-6.1-sol-20260101",
                "gpt-6.1-sol-20260201",
                "gpt-6.1-sol-20260230",
            ],
            "gpt-6.1-sol-20260201",
        ),
    ] {
        assert_eq!(
            selected(resolve("standard", &context("openai", &ids)))
                .concrete_id
                .as_deref(),
            Some(expected)
        );
    }
    let opus_context = context(
        "anthropic",
        &[
            "claude-opus-5-5-20260101",
            "claude-opus-5.6",
            "claude-opus-50-preview",
        ],
    );
    assert_eq!(
        selected(resolve("standard", &opus_context))
            .concrete_id
            .as_deref(),
        Some("claude-opus-5.6")
    );
    for (ids, expected) in [
        (
            vec![
                "claude-sonnet-5-9",
                "claude-sonnet-5-10",
                "claude-sonnet-99-preview",
                "claude-opus-9",
            ],
            "claude-sonnet-5-10",
        ),
        (
            vec![
                "claude-sonnet-5-20260101",
                "claude-sonnet-5",
                "claude-sonnet-5-20260201",
            ],
            "claude-sonnet-5",
        ),
        (
            vec![
                "claude-sonnet-5-20260101",
                "claude-sonnet-5-20260201",
                "claude-sonnet-5-20260230",
            ],
            "claude-sonnet-5-20260201",
        ),
        (
            vec![
                "claude-3-5-sonnet-20241022",
                "claude-3-7-sonnet-20250219",
                "claude-3-haiku-20240307",
                "claude-3-opus-20240229",
            ],
            "claude-3-7-sonnet-20250219",
        ),
    ] {
        let mut context = context("anthropic", &ids);
        if let ModelListEvidence::Complete { models, .. } = &mut context.models {
            for model in models {
                model.native_selector = Some(format!("anthropic/{}", model.id));
            }
        }
        assert_eq!(
            selected(resolve("anthropic/sonnet", &context))
                .concrete_id
                .as_deref(),
            Some(expected)
        );
        let policy = BTreeMap::from([("light".into(), "anthropic/sonnet".into())]);
        let request = ModelRequest::parse("light").unwrap();
        let result = resolve_model(&request, ResolutionContext::Runtime(&context), &policy);
        let selection = selected(result);
        assert_eq!(selection.concrete_id.as_deref(), Some(expected));
        assert_eq!(selection.effective_class, Some(ModelClass::Light));
    }
}
#[test]
fn unknown_access_and_empty_inventory_keep_native_default_without_invention() {
    let evidence = [
        ModelListEvidence::Unsupported {
            source: "fixture:no-interface".into(),
        },
        ModelListEvidence::Failed {
            source: "fixture:reader".into(),
            cause: "read failed".into(),
        },
        ModelListEvidence::Complete {
            source: "fixture:empty".into(),
            account: "fixture-account".into(),
            host: "fixture-host".into(),
            models: vec![],
        },
    ];
    for models in evidence {
        let mut context = context("openai", &[]);
        context.models = models;
        for request in ["fast", "gpt-6-astra"] {
            // Confirmed missing exact pins differ from unknown access.
            if request == "gpt-6-astra"
                && matches!(context.models, ModelListEvidence::Complete { .. })
            {
                assert!(
                    matches!(resolve(request, &context), ModelResolution::Refused { code, .. } if code == "model-unavailable")
                );
                continue;
            }
            let result = resolve(request, &context);
            match result {
                ModelResolution::HarnessDefault {
                    request: original,
                    path,
                    capacity,
                    diagnostics,
                } => {
                    assert_eq!(original.selector(), request);
                    assert_eq!(path, HarnessModelPath::NativeDefault);
                    assert!(matches!(capacity, ModelCapacityEvidence::Unknown { .. }));
                    assert!(
                        diagnostics
                            .iter()
                            .any(|d| d.code == "model-availability-unknown")
                    );
                    if matches!(context.models, ModelListEvidence::Failed { .. }) {
                        assert!(diagnostics.iter().any(|d| d.code == "model-list-failed"
                            && d.source.as_deref() == Some("fixture:reader")));
                    }
                    if request == "gpt-6-astra" {
                        assert!(diagnostics.iter().any(|d| d.code == "old-id"));
                    }
                }
                other => panic!("unknown access must preserve default: {other:?}"),
            }
        }
    }
}
#[test]
fn unknown_capacity_does_not_borrow_another_model_measurement() {
    let mut context = context("openai", &["gpt-6.1-terra", "gpt-6.1-luna"]);
    context.capacity.retain(|e| matches!(e, ModelCapacityEvidence::Known { selector, .. } if selector.ends_with("luna")));
    let result = resolve("fast", &context);
    assert!(
        result
            .diagnostics()
            .iter()
            .any(|d| d.code == "model-capacity-unknown")
    );
    assert!(matches!(
        result,
        ModelResolution::HarnessDefault {
            path: HarnessModelPath::NativeDefault,
            capacity: ModelCapacityEvidence::Unknown { .. },
            ..
        }
    ));
}
#[test]
fn affirmative_no_model_refuses_and_known_pin_never_upgrades() {
    let mut context = context("openai", &["gpt-6.1-sol", "gpt-7-sol"]);
    assert_eq!(
        selected(resolve("gpt-6.1-sol", &context))
            .concrete_id
            .as_deref(),
        Some("gpt-6.1-sol")
    );
    context.models = ModelListEvidence::Unsupported {
        source: "fixture:none".into(),
    };
    context.default = HarnessModelPath::NoUsableModel {
        source: "fixture:default".into(),
        cause: "affirmative no usable path".into(),
    };
    assert!(
        matches!(resolve("top", &context), ModelResolution::Refused { code, .. } if code == "no-model")
    );
}
#[test]
fn excluded_haiku_reads_both_claude_id_orders() {
    for (id, excluded) in [
        ("haiku", true),
        ("claude-haiku-4-5", true),
        ("claude-haiku-4-5-20251001", true),
        ("claude-3-haiku-20240307", true),
        ("claude-3-5-haiku-20241022", true),
        ("claude-3-5-haiku", true),
        ("claude-haiku-4-6", false),
        ("claude-haiku-5", false),
        ("claude-3-5-sonnet-20241022", false),
        ("claude-3-haikus-20240307", false),
    ] {
        assert_eq!(family::excluded_haiku(id), excluded, "{id}");
    }
}
#[test]
fn exact_haiku_compatibility_substitution_stops_at_four_point_five() {
    // Native model lists supply the exact pins and their model-bound capacity.
    for (id, expected, effective, causes) in [
        (
            "claude-haiku-4",
            "claude-sonnet-5",
            Some(ModelClass::Light),
            vec!["old-id", "excluded-haiku", "fallback"],
        ),
        (
            "claude-haiku-4-5",
            "claude-sonnet-5",
            Some(ModelClass::Light),
            vec!["old-id", "excluded-haiku", "fallback"],
        ),
        (
            "claude-haiku-4-5-20251001",
            "claude-sonnet-5",
            Some(ModelClass::Light),
            vec!["old-id", "excluded-haiku", "fallback"],
        ),
        (
            "claude-3-haiku-20240307",
            "claude-sonnet-5",
            Some(ModelClass::Light),
            vec!["old-id", "excluded-haiku", "fallback"],
        ),
        (
            "claude-3-5-haiku-20241022",
            "claude-sonnet-5",
            Some(ModelClass::Light),
            vec!["old-id", "excluded-haiku", "fallback"],
        ),
        ("claude-haiku-4-6", "claude-haiku-4-6", None, vec!["old-id"]),
        ("claude-haiku-5", "claude-haiku-5", None, vec!["old-id"]),
    ] {
        let context = context("anthropic", &[id, "claude-sonnet-5"]);
        let request = format!("anthropic/{id}");
        // Installed Pi frontmatter is the producer of the later dispatch request.
        let rendered = render_model(HarnessId::Pi, &request, &BTreeMap::new(), &BTreeMap::new());
        assert_eq!(rendered.id.as_deref(), Some(request.as_str()));
        let result = resolve(rendered.id.as_deref().unwrap(), &context);
        assert_eq!(
            result
                .diagnostics()
                .iter()
                .map(|d| d.code.as_str())
                .collect::<Vec<_>>(),
            causes,
            "{id}"
        );
        let warning = result
            .warning(&ModelRequest::parse(&request).unwrap())
            .unwrap();
        assert_eq!(warning.lines().count(), 1);
        assert!(warning.contains(&format!(
            "requested={request} selected=anthropic/{expected}"
        )));
        let selection = selected(result);
        assert_eq!(selection.native_selector, format!("anthropic/{expected}"));
        assert_eq!(selection.concrete_id.as_deref(), Some(expected));
        assert_eq!(selection.effective_class, effective);
    }
}

#[test]
fn overrides_replace_members_but_do_not_create_access() {
    let custom_context = context("custom", &["old", "new"]);
    let personal = BTreeMap::from([("fast".into(), "custom/old".into())]);
    let project = BTreeMap::from([("fast".into(), "custom/new".into())]);
    let policy = effective_overrides(&personal, &project);
    let request = ModelRequest::parse("fast").unwrap();
    let result = resolve_model(
        &request,
        ResolutionContext::Runtime(&custom_context),
        &policy,
    );
    assert_eq!(selected(result).concrete_id.as_deref(), Some("new"));
    let missing = BTreeMap::from([("fast".into(), "custom/unavailable".into())]);
    let result = resolve_model(
        &request,
        ResolutionContext::Runtime(&custom_context),
        &missing,
    );
    assert_ne!(selected(result).concrete_id.as_deref(), Some("unavailable"));
    let context = context("openai", &["gpt-6.1-luna"]);
    let policy = BTreeMap::from([("standard".into(), "openai/gpt-6.1-sol".into())]);
    let rendered = render_model(HarnessId::Pi, "standard", &policy, &BTreeMap::new());
    let request = ModelRequest::parse(rendered.id.as_deref().unwrap()).unwrap();
    assert_eq!(request.class(), Some(ModelClass::Standard));
    let result = resolve_model(&request, ResolutionContext::Runtime(&context), &policy);
    assert!(result.diagnostics().iter().any(|d| d.code == "fallback"));
    let selection = selected(result);
    assert_eq!(selection.effective_class, Some(ModelClass::Light));
    assert_eq!(selection.native_selector, "openai/gpt-6.1-luna");
}

#[test]
fn nested_provider_ids_validate_for_inventory_parent_and_exact_requests() {
    let id = "anthropic/claude-sonnet-4";
    let selector = format!("openrouter/{id}");
    let mut context = context("openrouter", &[id]);
    context.default = HarnessModelPath::ObservedSessionOrDefault {
        selector: selector.clone(),
        provider: Some("openrouter".into()),
        id: Some(id.into()),
        account: context.account.clone(),
        host: context.host.clone(),
        source: "fixture:parent".into(),
    };
    assert!(context.validate(HarnessId::Pi).is_ok());
    assert_eq!(resolve("inherit", &context), ModelResolution::Inherit);
    assert_eq!(
        selected(resolve(&selector, &context)).native_selector,
        selector
    );
    assert!(matches!(
        resolve(id, &context),
        ModelResolution::Refused { code, .. } if code == "model-unavailable"
    ));
    let request = ModelRequest::parse("light").unwrap();
    for (replacement, expected) in [(id, None), (selector.as_str(), Some(ModelClass::Light))] {
        let policy = BTreeMap::from([("light".into(), replacement.into())]);
        let result = resolve_model(&request, ResolutionContext::Runtime(&context), &policy);
        assert_eq!(selected(result).effective_class, expected);
    }
    let bare = self::context("custom", &["listed-model"]);
    assert_eq!(
        selected(resolve("listed-model", &bare)).native_selector,
        "custom/listed-model"
    );
    if let ModelListEvidence::Complete { models, .. } = &mut context.models {
        models[0].native_selector = Some("gateway/native-selector".into());
    }
    if let ModelCapacityEvidence::Known { selector, .. } = &mut context.capacity[0] {
        *selector = "gateway/native-selector".into();
    }
    assert_eq!(
        selected(resolve("gateway/native-selector", &context)).native_selector,
        "gateway/native-selector"
    );
}

#[test]
fn combined_warning_keeps_failed_source_cause_on_one_line() {
    let mut context = context("openai", &[]);
    context.models = ModelListEvidence::Failed {
        source: "codex:model/list".into(),
        cause: "app-server exited with code 7\nRPC failed".into(),
    };
    let request = ModelRequest::parse("standard").unwrap();
    let result = resolve_model(
        &request,
        ResolutionContext::Runtime(&context),
        &BTreeMap::new(),
    );
    let warning = result.warning(&request).unwrap();
    assert_eq!(warning.lines().count(), 1);
    assert!(warning.contains("codex:model/list"));
    assert!(warning.contains("app-server exited with code 7 RPC failed"));
    let refusal = ModelResolution::Refused {
        code: "model-unavailable".into(),
        diagnostics: result.diagnostics().to_vec(),
    };
    assert!(
        refusal
            .warning(&request)
            .unwrap()
            .contains("app-server exited with code 7 RPC failed")
    );
}
#[test]
fn evidence_binding_policy_and_rejected_candidates() {
    let mut context = context("openai", &["gpt-6.1-terra", "gpt-6.1-luna"]);
    context.rejected.push("openai/gpt-6.1-terra".into());
    assert_eq!(
        selected(resolve("fast", &context)).effective_class,
        Some(ModelClass::Light)
    );
    if let ModelListEvidence::Complete { models, .. } = &mut context.models {
        models[1].allowed = false;
    }
    assert!(matches!(
        resolve("fast", &context),
        ModelResolution::HarnessDefault { .. }
    ));
    context.host = "different-host".into();
    assert!(context.validate(HarnessId::Pi).is_err());
    context.host = "fixture-host".into();
    assert!(context.validate(HarnessId::Pi).is_ok());
    if let ModelListEvidence::Complete { models, .. } = &mut context.models {
        models.push(AvailableModel {
            provider: "anthropic".into(),
            ..models[0].clone()
        });
    }
    assert!(context.validate(HarnessId::Pi).is_err());
}
#[test]
fn observed_native_default_cannot_restore_a_denied_selection() {
    // Runtime callbacks supply observed defaults and rejected selectors beside native lists.
    for (provider, id, allowed, rejected) in [
        ("openai", "gpt-6.1-sol", false, false),
        ("openai", "gpt-6.1-sol", true, true),
        ("anthropic", "claude-haiku-4-5", true, false),
    ] {
        let mut context = context(provider, &[id]);
        let selector = format!("{provider}/{id}");
        context.default = HarnessModelPath::ObservedSessionOrDefault {
            selector: selector.clone(),
            provider: Some(provider.into()),
            id: Some(id.into()),
            account: context.account.clone(),
            host: context.host.clone(),
            source: "fixture:native-session".into(),
        };
        context.capacity.clear();
        if let ModelListEvidence::Complete { models, .. } = &mut context.models {
            models[0].allowed = allowed;
        }
        if rejected {
            context.rejected.push(selector);
        }
        assert!(
            matches!(resolve("standard", &context), ModelResolution::Refused { code, .. } if code == "model-unavailable"),
            "{provider}/{id}"
        );
    }
}

#[test]
fn collector_missing_active_provider_is_failed_not_complete_empty() {
    // Codex model/list has no provider field; runtime callers must bind its active provider.
    let mut context = context("openai", &[]);
    context.current_provider = None;
    context.providers.push("custom".into());
    let tmp = tempfile::tempdir().unwrap();
    let cwd = crate::test_util::rooted(&tmp);
    let evidence = codex::collect(&context, &cwd);
    assert!(
        matches!(evidence, ModelListEvidence::Failed { source, cause }
            if source == "codex:model/list" && !cause.is_empty())
    );
}
#[test]
fn native_alias_and_renderer_boundaries() {
    for harness in HarnessId::ALL {
        assert!(
            render_model(harness, "inherit", &BTreeMap::new(), &BTreeMap::new())
                .id
                .is_none()
        );
        let pin = "anthropic/claude-haiku-4-5";
        assert_eq!(
            render_model(harness, pin, &BTreeMap::new(), &BTreeMap::new())
                .id
                .as_deref(),
            Some(pin)
        );
        let hint = resolve_model(
            &ModelRequest::parse(pin).unwrap(),
            ResolutionContext::SelectorHint(harness),
            &BTreeMap::new(),
        );
        assert!(
            matches!(hint, ModelResolution::NativeAlias { native_selector, .. } if native_selector == pin)
        );
    }
    assert_eq!(
        render_model(
            HarnessId::Claude,
            "fast",
            &BTreeMap::new(),
            &BTreeMap::new()
        )
        .id
        .as_deref(),
        Some("sonnet")
    );
    assert_eq!(
        render_model(
            HarnessId::Claude,
            "anthropic/opus",
            &BTreeMap::new(),
            &BTreeMap::new()
        )
        .id
        .as_deref(),
        Some("opus")
    );
    for harness in [
        HarnessId::Codex,
        HarnessId::Copilot,
        HarnessId::Opencode,
        HarnessId::Gemini,
        HarnessId::Antigravity,
        HarnessId::Cursor,
    ] {
        for class in ["top", "standard", "light", "fast"] {
            assert!(
                render_model(harness, class, &BTreeMap::new(), &BTreeMap::new())
                    .id
                    .is_none()
            );
        }
    }
    for class in ["top", "standard", "light", "fast"] {
        assert_eq!(
            render_model(HarnessId::Pi, class, &BTreeMap::new(), &BTreeMap::new())
                .id
                .as_deref(),
            Some(class)
        );
    }
}

#[test]
fn guard_render_blind_rows_are_the_pi_values_that_render_no_model() {
    let guard = std::fs::read_to_string(
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tools/guard"),
    )
    .unwrap();
    let table = guard
        .split_once("render_blind='")
        .and_then(|(_, rest)| rest.split_once('\''))
        .unwrap()
        .0;
    let rows: std::collections::BTreeSet<_> = table
        .lines()
        .map(|row| match row.split(' ').collect::<Vec<_>>()[..] {
            [root, "model", value, rendered] => (root, value.to_owned(), rendered.to_owned()),
            _ => panic!("{row}"),
        })
        .collect();
    // The token each root's file carries when render_model selects nothing:
    // Claude spells inheritance literally, Codex and Pi omit the line.
    let roots = [
        (".claude/agents", HarnessId::Claude, "inherit"),
        (".codex/agents", HarnessId::Codex, "-"),
        (".pi/agents", HarnessId::Pi, "-"),
    ];
    let values = ["inherit", "current", "parent"]
        .into_iter()
        .chain(TIERS.iter().flat_map(|row| [row.name, row.legacy]));
    let expected: std::collections::BTreeSet<_> = roots
        .into_iter()
        .flat_map(|(root, harness, omitted)| {
            values.clone().map(move |value| {
                let rendered = render_model(harness, value, &BTreeMap::new(), &BTreeMap::new()).id;
                (
                    root,
                    value.to_owned(),
                    rendered.unwrap_or_else(|| omitted.to_owned()),
                )
            })
        })
        .collect();
    assert_eq!(rows, expected);
}
