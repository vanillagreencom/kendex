//! What each `kendex://` URL has to come out as, and the handoff's rule.

use super::*;

fn marketplace(repo: &str) -> DeepLink {
    DeepLink::Marketplace {
        repo: repo.to_string(),
    }
}

fn package(repo: &str, kind: ItemKind, name: &str) -> DeepLink {
    DeepLink::Package {
        repo: repo.to_string(),
        kind,
        name: name.to_string(),
    }
}

#[test]
fn the_two_paths_open_what_the_website_names() {
    let cases = [
        (
            "kendex://m/vanillagreencom/kendex",
            marketplace("vanillagreencom/kendex"),
        ),
        // A trailing slash and letter case say nothing about which
        // repository it is, the same fold every subscription gets.
        (
            "kendex://m/VanillaGreenCom/Kendex/",
            marketplace("vanillagreencom/kendex"),
        ),
        (
            "kendex://m/vanillagreencom/kendex/agent/generalist",
            package("vanillagreencom/kendex", ItemKind::Agent, "generalist"),
        ),
        // The site's spelling of the one kind kendex names differently.
        (
            "kendex://m/acme/kit/mcp/context7",
            package("acme/kit", ItemKind::McpServer, "context7"),
        ),
        (
            "kendex://m/acme/kit/pi-extension/pi-agents",
            package("acme/kit", ItemKind::PiExtension, "pi-agents"),
        ),
        // A name arrives percent-encoded from a browser and is looked up
        // as spelled.
        (
            "kendex://m/acme/kit/skill/my%20skill",
            package("acme/kit", ItemKind::Skill, "my skill"),
        ),
    ];
    for (url, expected) in cases {
        assert_eq!(parse(url), expected, "{url}");
    }
}

/// No two kinds share a site spelling: the parser finds each kind back
/// from its own spelling. A kind added to core without a spelling is the
/// exhaustive match in `site_kind`, at compile time; the spellings
/// themselves are pinned by the cases above.
#[test]
fn every_kind_has_a_site_spelling_that_parses_back() {
    for kind in ItemKind::ALL {
        let url = format!("kendex://m/acme/kit/{}/thing", site_kind(kind));
        assert_eq!(parse(&url), package("acme/kit", kind, "thing"), "{url}");
    }
}

#[test]
fn a_url_the_app_cannot_follow_is_refused_naming_the_part() {
    let cases = [
        ("kendex://m", "no marketplace is named"),
        ("kendex://m/onlyowner", "no marketplace is named"),
        (
            "kendex://m/acme/kit/agent",
            "no package name follows 'agent'",
        ),
        (
            "kendex://m/acme/kit/widget/thing",
            "'widget' is not a package kind",
        ),
        // kendex's own spelling is not the site's; the contract is the
        // site's.
        (
            "kendex://m/acme/kit/mcp-server/thing",
            "'mcp-server' is not a package kind",
        ),
        (
            "kendex://m/acme/kit/agent/thing/extra",
            "more parts than <owner>/<repo>/<kind>/<name>",
        ),
        (
            "kendex://p/acme/kit",
            "only kendex://m/<owner>/<repo> links",
        ),
        ("https://kendex.ai/m/acme/kit", "not a kendex:// link"),
        ("kendex://m/acme:x/kit", "not a GitHub owner and repository"),
        ("not a url", "not a URL"),
        ("kendex://m/acme/kit/skill/%ff", "not readable text"),
    ];
    for (url, part) in cases {
        match parse(url) {
            DeepLink::Refused { reason } => {
                assert!(reason.contains(part), "{url}: {reason}");
                assert!(reason.contains(url), "{url}: the refusal names the link");
            }
            other => panic!("{url} opened as {other:?}"),
        }
    }
}

/// Before the page asks every URL is held and the latest wins; the ask
/// hands the held one over and switches every later URL to emission.
#[test]
fn urls_are_held_until_the_page_asks_and_emitted_after() {
    let links = DeepLinks::default();
    assert_eq!(links.route(marketplace("acme/first")), Route::Held);
    assert_eq!(links.route(marketplace("acme/second")), Route::Held);
    assert_eq!(links.take(), Some(marketplace("acme/second")));
    assert_eq!(
        links.route(marketplace("acme/third")),
        Route::Emit(marketplace("acme/third"))
    );
    // A page reload asks again: nothing is held, and delivery stays live.
    assert_eq!(links.take(), None);
    assert_eq!(
        links.route(marketplace("acme/fourth")),
        Route::Emit(marketplace("acme/fourth"))
    );
}
