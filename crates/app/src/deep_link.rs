//! The `kendex://` URLs the website's "Open in app" buttons open: what one
//! asks the app to show, and how it reaches the page.
//!
//! The paths mirror the website's own, `kendex.ai/m/<owner>/<repo>` and
//! `kendex.ai/m/<owner>/<repo>/<kind>/<name>`, so the website builds a link
//! by swapping the scheme. A marketplace opens the way the Community tab
//! opens a repository before anyone subscribes; a package opens that
//! repository's package page. A link writes no manifest and no
//! subscription, because it comes from a web page; what it does cause is
//! the read the Community tab causes, the repository fetched into the
//! mirror store so the page can show it.
//!
//! Delivery has two halves because the page is not there yet when the app
//! is launched by a link. A URL that arrives before the page has asked is
//! held, and `deep_link_take` hands it over once the page has rendered; a
//! URL that arrives after that is emitted as [`DeepLinkOpened`], which the
//! page listens for before it asks. Only the latest held URL is kept: two
//! clicks before the first render mean the second is what the person wants
//! to see.

use std::sync::{Mutex, MutexGuard, PoisonError};

use kendex_core::model::ItemKind;
use tauri::Manager;
use tauri_plugin_deep_link::DeepLinkExt;
use tauri_specta::Event;

/// The scheme the app registers and the only one a link may carry.
pub const SCHEME: &str = "kendex";

/// The one host the website's paths sit under.
const MARKETPLACE_HOST: &str = "m";

/// Where a `kendex://` URL asks the app to go, or why it cannot.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, specta::Type)]
#[serde(tag = "open", rename_all = "kebab-case")]
pub enum DeepLink {
    /// `kendex://m/<owner>/<repo>`: one marketplace, keyed by the
    /// canonical `owner/repo` every marketplace read is addressed by.
    Marketplace { repo: String },
    /// `kendex://m/<owner>/<repo>/<kind>/<name>`: one package that
    /// marketplace offers.
    Package {
        repo: String,
        kind: ItemKind,
        name: String,
    },
    /// Nothing the app can open. The page shows the marketplace list with
    /// `reason` beside it, so a stale or mistyped link says so rather than
    /// landing nowhere.
    Refused { reason: String },
}

/// The kind segment the website spells a package's kind as. Six kinds
/// share kendex's own name; MCP servers are `mcp` on the site.
fn site_kind(kind: ItemKind) -> &'static str {
    match kind {
        ItemKind::McpServer => "mcp",
        ItemKind::Agent
        | ItemKind::Skill
        | ItemKind::Hook
        | ItemKind::Command
        | ItemKind::Plugin
        | ItemKind::PiExtension => kind.name(),
    }
}

/// Every segment of the URL's path, percent-decoded, with the empty
/// segment a trailing slash leaves dropped. Refused when a segment is not
/// UTF-8 once decoded: a name that cannot be spelled cannot be looked up.
fn segments(url: &url::Url) -> Result<Vec<String>, String> {
    let Some(raw) = url.path_segments() else {
        return Ok(Vec::new());
    };
    let mut decoded = Vec::new();
    for segment in raw {
        if segment.is_empty() {
            continue;
        }
        match percent_encoding::percent_decode_str(segment).decode_utf8() {
            Ok(text) => decoded.push(text.into_owned()),
            Err(_) => return Err(format!("'{segment}' is not readable text")),
        }
    }
    Ok(decoded)
}

/// What one URL asks for. Every refusal names the part of the URL it
/// could not follow, in the words the page shows.
pub fn parse(url: &str) -> DeepLink {
    match target(url) {
        Ok(link) => link,
        Err(reason) => DeepLink::Refused {
            reason: format!("kendex can't open {url}: {reason}."),
        },
    }
}

fn target(raw: &str) -> Result<DeepLink, String> {
    let url = url::Url::parse(raw).map_err(|error| format!("not a URL ({error})"))?;
    if url.scheme() != SCHEME {
        return Err(format!("the link is not a {SCHEME}:// link"));
    }
    if url.host_str() != Some(MARKETPLACE_HOST) {
        return Err(format!(
            "only {SCHEME}://{MARKETPLACE_HOST}/<owner>/<repo> links open here"
        ));
    }
    let segments = segments(&url)?;
    let (owner, repo, rest) = match segments.as_slice() {
        [owner, repo, rest @ ..] => (owner, repo, rest),
        _ => return Err("no marketplace is named (expected <owner>/<repo>)".to_string()),
    };
    let repo = kendex_core::source_ref::owner_repo(&format!("{owner}/{repo}"))
        .ok_or_else(|| format!("'{owner}/{repo}' is not a GitHub owner and repository"))?;
    match rest {
        [] => Ok(DeepLink::Marketplace { repo }),
        [kind, name] => {
            let kind = ItemKind::ALL
                .into_iter()
                .find(|candidate| site_kind(*candidate) == kind)
                .ok_or_else(|| format!("'{kind}' is not a package kind"))?;
            Ok(DeepLink::Package {
                repo,
                kind,
                name: name.clone(),
            })
        }
        [kind] => Err(format!("no package name follows '{kind}'")),
        _ => Err("the path has more parts than <owner>/<repo>/<kind>/<name>".to_string()),
    }
}

/// A URL the app was asked to open while the page was listening.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, specta::Type, tauri_specta::Event)]
pub struct DeepLinkOpened(pub DeepLink);

/// The URL waiting for the page, and whether the page has asked yet. One
/// lock holds both so a URL cannot land between the page's first ask and
/// its listener seeing it: before the ask every URL is held, after it every
/// URL is emitted.
pub struct DeepLinks(Mutex<Handoff>);

#[derive(Default)]
struct Handoff {
    held: Option<DeepLink>,
    page_listening: bool,
}

impl Default for DeepLinks {
    fn default() -> Self {
        Self(Mutex::new(Handoff::default()))
    }
}

impl DeepLinks {
    /// A panic while a URL was being handed over leaves the URL, not the
    /// process: the page still gets whatever was held.
    fn held(&self) -> MutexGuard<'_, Handoff> {
        self.0.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Where a URL goes: to the page, or into the slot the page's first ask
    /// empties. Answers what was emitted so the caller can say when the
    /// webview would not take it.
    fn route(&self, link: DeepLink) -> Route {
        let mut handoff = self.held();
        if handoff.page_listening {
            Route::Emit(link)
        } else {
            handoff.held = Some(link);
            Route::Held
        }
    }

    /// The page's first ask, and every reload's: from here on URLs are
    /// emitted, and the one held for the page, if any, goes with the answer.
    fn take(&self) -> Option<DeepLink> {
        let mut handoff = self.held();
        handoff.page_listening = true;
        handoff.held.take()
    }
}

#[derive(Debug, PartialEq, Eq)]
enum Route {
    Emit(DeepLink),
    Held,
}

/// Hand a URL to the page, or hold it until the page asks.
pub fn deliver(app: &tauri::AppHandle, url: &str) {
    let link = parse(url);
    let Route::Emit(link) = app.state::<DeepLinks>().route(link) else {
        return;
    };
    if let Err(error) = DeepLinkOpened(link).emit(app) {
        use std::io::Write;
        let _ = writeln!(std::io::stderr(), "deep link not delivered: {error}");
    }
}

/// The URL that launched the app, if one did, held for the page; every
/// URL after that routed as it arrives. On Linux and Windows the scheme is
/// registered for this binary on launch, which is the only registration a
/// build run from a checkout gets; on macOS the bundle's `Info.plist`
/// carries it and there is nothing to do at runtime. A sandboxed build
/// registers nothing: the handler file and the mime default are the real
/// machine's, and a link pointed at a `target/` binary is dead the day
/// that binary goes. Registration runs off the main thread, since it
/// waits on two desktop tools and the window is already showing; one
/// that fails is said the way launch recovery is said, on stderr, and
/// the app still opens.
///
/// The `DeepLinks` state is managed on the builder, not here: the page
/// can ask before setup has run, and a state managed here would answer
/// that ask with "not managed".
pub fn wire(app: &tauri::App) {
    if kendex_core::env::sandboxed() {
        use std::io::Write;
        let _ = writeln!(
            std::io::stderr(),
            "sandboxed build: {SCHEME}:// links stay with the installed app (KENDEX_REAL_HOME=1 registers this one)"
        );
    } else {
        let handle = app.handle().clone();
        std::thread::spawn(move || {
            if let Err(error) = register(&handle) {
                use std::io::Write;
                let _ = writeln!(
                    std::io::stderr(),
                    "{SCHEME}:// links will not reach this app: {error}"
                );
            }
        });
    }
    let handle = app.handle().clone();
    app.deep_link().on_open_url(move |event| {
        for url in event.urls() {
            deliver(&handle, url.as_str());
        }
    });
    if let Ok(Some(urls)) = app.deep_link().get_current() {
        for url in urls {
            deliver(app.handle(), url.as_str());
        }
    }
}

/// The page's ask, after its first render: the URL that launched the app,
/// if one did. Asking is also what switches delivery to events, so the
/// page listens before it asks.
#[tauri::command]
#[specta::specta]
pub fn deep_link_take(links: tauri::State<'_, DeepLinks>) -> Option<DeepLink> {
    links.take()
}

/// Linux writes its own handler file (`linux.rs` says why); Windows takes
/// the plugin's registry entries; macOS has nothing to do at runtime.
fn register(app: &tauri::AppHandle) -> Result<(), String> {
    #[cfg(target_os = "linux")]
    {
        linux::register(app)
    }
    #[cfg(windows)]
    {
        app.deep_link()
            .register_all()
            .map_err(|error| error.to_string())
    }
    #[cfg(not(any(target_os = "linux", windows)))]
    {
        let _ = app;
        Ok(())
    }
}

#[cfg(target_os = "linux")]
mod linux;

#[cfg(test)]
mod tests;
