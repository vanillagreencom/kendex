//! Which sign-in an identity read belongs to. Everything here drives a
//! credential changing while a read is in flight: logout winning the
//! race, a sign-out landing mid-read, a sign-in as somebody else before
//! or after the call, and a refresh rotation, which changes both tokens
//! and is the one case that must still settle. The transports and stores
//! here exist to place that change at an exact point in `load`.

use std::cell::{Cell, RefCell};

use kendex_core::env::Env;
use kendex_core::error::{CoreError, Result};
use kendex_core::registry::credentials::{Credential, CredentialRefreshGuard, CredentialStore};
use kendex_core::registry::me::{self, AccountState};
use kendex_core::registry::submit;
use kendex_core::registry::{Fetch, FetchResponse};

use super::{ADA, Canned, MemoryGuard, MemoryStore, away, env_in, fixture_body, ok, write_cache};

/// A store whose credential disappears after N loads — logout winning a
/// race against the read.
struct VanishingStore {
    loads_before_gone: RefCell<u32>,
    credential: Credential,
}

impl CredentialStore for VanishingStore {
    fn save(&self, _credential: &Credential) -> Result<()> {
        Ok(())
    }
    fn load(&self) -> Result<Option<Credential>> {
        let mut left = self.loads_before_gone.borrow_mut();
        if *left == 0 {
            return Ok(None);
        }
        *left -= 1;
        Ok(Some(self.credential.clone()))
    }
    fn clear(&self) -> Result<()> {
        Ok(())
    }
    fn refresh_guard(&self) -> Result<Box<dyn CredentialRefreshGuard + '_>> {
        Ok(Box::new(MemoryGuard))
    }
}

/// A transport that lets the sign-out — and, when one is given, the
/// sign-in that follows it — land while the identity request is still
/// outstanding. That is the only moment the race is reachable inside one
/// process: the request hangs on the curl cap while the user signs out
/// and completes a device flow as somebody else.
struct RacingFetch<'a> {
    env: &'a Env,
    store: &'a MemoryStore,
    signs_in_as: Option<Credential>,
    answer: RefCell<Option<Result<FetchResponse>>>,
    raced: Cell<bool>,
}

impl<'a> RacingFetch<'a> {
    fn new(
        env: &'a Env,
        store: &'a MemoryStore,
        signs_in_as: Option<Credential>,
        answer: Result<FetchResponse>,
    ) -> RacingFetch<'a> {
        RacingFetch {
            env,
            store,
            signs_in_as,
            answer: RefCell::new(Some(answer)),
            raced: Cell::new(false),
        }
    }
}

impl Fetch for RacingFetch<'_> {
    fn get_auth(
        &self,
        _url: &str,
        _if_none_match: Option<&str>,
        _bearer: Option<&str>,
    ) -> Result<FetchResponse> {
        if !self.raced.replace(true) {
            let revoke = Canned::new(vec![ok(200, None, "{}")]);
            me::sign_out(self.env, &revoke, self.store).expect("sign out mid-read");
            if let Some(next) = &self.signs_in_as {
                me::commit_sign_in(self.env, self.store, next).expect("sign in mid-read");
            }
        }
        self.answer
            .borrow_mut()
            .take()
            .expect("the read asked twice")
    }

    fn post_json_auth(
        &self,
        _url: &str,
        _body: &str,
        _bearer: Option<&str>,
    ) -> Result<FetchResponse> {
        panic!("the identity read posts nothing")
    }
}

/// A store that lets an identity read settle inside the window
/// `commit_sign_in` opens between forgetting the cache and saving the new
/// credential. The old credential really is still installed there, so
/// that settle is legitimate and nothing but a second forget clears it.
struct SettlingStore<'a> {
    inner: MemoryStore,
    env: &'a Env,
    body: String,
}

impl CredentialStore for SettlingStore<'_> {
    fn save(&self, credential: &Credential) -> Result<()> {
        write_cache(self.env, &self.body, None, Some(ADA));
        self.inner.save(credential)
    }
    fn load(&self) -> Result<Option<Credential>> {
        self.inner.load()
    }
    fn clear(&self) -> Result<()> {
        self.inner.clear()
    }
    fn refresh_guard(&self) -> Result<Box<dyn CredentialRefreshGuard + '_>> {
        self.inner.refresh_guard()
    }
}

/// A store that hands out one credential for the first `loads` reads and
/// somebody else's after that. Two reads in, `load` has taken its own
/// credential and read the cache under it, and the call is about to read
/// the store for itself: that is the window a sign-in lands in.
struct SwitchingStore {
    loads: RefCell<u32>,
    before: Credential,
    after: Credential,
}

impl SwitchingStore {
    fn after(loads: u32) -> SwitchingStore {
        SwitchingStore {
            loads: RefCell::new(loads),
            before: MemoryStore::signed_in().0.into_inner().expect("credential"),
            after: other_account(),
        }
    }
}

impl CredentialStore for SwitchingStore {
    fn save(&self, _credential: &Credential) -> Result<()> {
        Ok(())
    }
    fn load(&self) -> Result<Option<Credential>> {
        let mut left = self.loads.borrow_mut();
        if *left == 0 {
            return Ok(Some(self.after.clone()));
        }
        *left -= 1;
        Ok(Some(self.before.clone()))
    }
    fn clear(&self) -> Result<()> {
        Ok(())
    }
    fn refresh_guard(&self) -> Result<Box<dyn CredentialRefreshGuard + '_>> {
        Ok(Box::new(MemoryGuard))
    }
}

/// A store that jams the cache path shut as the sign-in saves: a
/// directory where the file goes, which `remove_file` refuses. The first
/// forget has already run by then, so this hits only the second.
struct JammingStore<'a> {
    inner: MemoryStore,
    env: &'a Env,
}

impl CredentialStore for JammingStore<'_> {
    fn save(&self, credential: &Credential) -> Result<()> {
        let jam = self.env.registry_cache_dir().join("me.cache.json");
        std::fs::create_dir_all(&jam).expect("jam the cache path");
        self.inner.save(credential)
    }
    fn load(&self) -> Result<Option<Credential>> {
        self.inner.load()
    }
    fn clear(&self) -> Result<()> {
        self.inner.clear()
    }
    fn refresh_guard(&self) -> Result<Box<dyn CredentialRefreshGuard + '_>> {
        self.inner.refresh_guard()
    }
}

fn other_account() -> Credential {
    Credential {
        endpoint: "https://kendex.ai".to_owned(),
        access_token: "kxa_other".to_owned(),
        refresh_token: "kxr_other".to_owned(),
        capabilities: vec![],
        sign_in: "sign-in-other".to_owned(),
    }
}

#[test]
fn logout_winning_the_race_reads_as_signed_out() {
    let dir = tempfile::tempdir().expect("tempdir");
    // The guard's read and with_access's first read still see the
    // credential; the locked re-read after the 401 finds it gone.
    let store = VanishingStore {
        loads_before_gone: RefCell::new(2),
        credential: Credential {
            endpoint: "https://kendex.ai".to_owned(),
            access_token: "kxa_old".to_owned(),
            refresh_token: "kxr_old".to_owned(),
            capabilities: vec![],
            sign_in: ADA.to_owned(),
        },
    };
    let fetch = Canned::new(vec![ok(401, None, r#"{"error":"invalid_token"}"#)]);
    let state = me::load(&env_in(dir.path()), &fetch, &store).expect("load");
    assert_eq!(state, AccountState::SignedOut);
    assert_eq!(
        *fetch.calls.borrow(),
        1,
        "no refresh is attempted once logout won"
    );
}

#[test]
fn a_read_settling_under_a_replacement_credential_is_discarded() {
    let dir = tempfile::tempdir().expect("tempdir");
    let env = env_in(dir.path());
    let store = MemoryStore::signed_in();
    // Ada's read is in flight when she signs out and somebody else signs
    // in. A credential is installed again by the time it settles, so
    // existence alone would wave this answer through.
    let racing = RacingFetch::new(
        &env,
        &store,
        Some(other_account()),
        ok(200, None, &fixture_body(&["success", "body"])),
    );
    let refused = me::load(&env, &racing, &store).expect_err("a stale identity must be refused");
    assert!(
        matches!(refused, CoreError::RegistryUnavailable { .. }),
        "a replaced credential is a retryable read, not an account state: got {refused:?}"
    );
    assert_eq!(
        store
            .load()
            .expect("load")
            .expect("credential")
            .access_token,
        "kxa_other",
        "the replacement stays installed; only the answer is dropped"
    );
    assert!(
        !env.registry_cache_dir().join("me.cache.json").exists(),
        "the previous account's identity must not be cached under its successor"
    );
}

#[test]
fn a_real_sign_out_mid_read_leaves_no_cached_identity() {
    let dir = tempfile::tempdir().expect("tempdir");
    let env = env_in(dir.path());
    let store = MemoryStore::signed_in();
    let racing = RacingFetch::new(
        &env,
        &store,
        None,
        ok(200, None, &fixture_body(&["success", "body"])),
    );
    assert_eq!(
        me::load(&env, &racing, &store).expect("load"),
        AccountState::SignedOut,
        "a removed credential is signed out, not a refused read"
    );
    assert!(
        !env.registry_cache_dir().join("me.cache.json").exists(),
        "a read finishing after sign-out must leave no identity on disk"
    );
}

#[test]
fn a_rotation_mid_read_still_settles_the_answer() {
    let dir = tempfile::tempdir().expect("tempdir");
    let env = env_in(dir.path());
    let store = MemoryStore::signed_in();
    // Refreshing replaces both tokens without changing who is signed in,
    // so the answer this read comes back with is still that account's.
    let fetch = Canned::new(vec![
        ok(401, None, r#"{"error":"invalid_token"}"#),
        ok(
            200,
            None,
            r#"{"access_token":"kxa_new","refresh_token":"kxr_new","capabilities":[]}"#,
        ),
        ok(200, None, &fixture_body(&["success", "body"])),
    ]);
    match me::load(&env, &fetch, &store).expect("load") {
        AccountState::SignedIn { identity, .. } => assert_eq!(identity.name, "Ada Lovelace"),
        other => panic!("a rotated sign-in is the same sign-in, got {other:?}"),
    }
    assert_eq!(
        store
            .load()
            .expect("load")
            .expect("credential")
            .refresh_token,
        "kxr_new",
        "the rotation is what makes this the case it is"
    );
    // Keyed to the credential the answer went out under, not the one the
    // read opened with, or the next read would find nothing.
    let down = Canned::new(vec![away()]);
    match me::load(&env, &down, &store).expect("offline load") {
        AccountState::Offline { identity, .. } => assert_eq!(identity.name, "Ada Lovelace"),
        other => panic!("the rotated read's cache is still this sign-in's, got {other:?}"),
    }
}

#[test]
fn a_sign_in_clears_an_identity_that_settled_while_it_committed() {
    let dir = tempfile::tempdir().expect("tempdir");
    let env = env_in(dir.path());
    let store = SettlingStore {
        inner: MemoryStore::signed_in(),
        env: &env,
        body: fixture_body(&["success", "body"]),
    };
    me::commit_sign_in(&env, &store, &other_account()).expect("commit");
    assert!(
        !env.registry_cache_dir().join("me.cache.json").exists(),
        "an identity cached before the new credential landed is still the old account's"
    );
}

/// The identity cached under one account, read into this call, and then
/// somebody else's credential installed before the request goes out. What
/// comes back from the server decides which route would serve the cache:
/// a 304 hands it back whole, a refused status and a transport failure
/// each serve it as offline. None of them may.
fn a_read_whose_sign_in_changed_before_the_call(
    env: &Env,
    etag: Option<&str>,
    answer: Result<FetchResponse>,
) -> Result<AccountState> {
    write_cache(env, &fixture_body(&["success", "body"]), etag, Some(ADA));
    let store = SwitchingStore::after(1);
    let fetch = Canned::new(vec![answer]);
    me::load(env, &fetch, &store)
}

#[test]
fn a_refused_status_never_serves_a_cache_from_another_sign_in() {
    let dir = tempfile::tempdir().expect("tempdir");
    let env = env_in(dir.path());
    let refused = a_read_whose_sign_in_changed_before_the_call(
        &env,
        None,
        ok(503, None, r#"{"error":"down"}"#),
    )
    .expect_err("the cached identity belongs to the previous account");
    assert!(
        matches!(refused, CoreError::RegistryUnavailable { .. }),
        "a changed sign-in is a retryable read: got {refused:?}"
    );
}

#[test]
fn a_304_never_serves_a_cache_from_another_sign_in() {
    let dir = tempfile::tempdir().expect("tempdir");
    let env = env_in(dir.path());
    assert!(
        a_read_whose_sign_in_changed_before_the_call(&env, Some("\"v1\""), ok(304, None, ""))
            .is_err(),
        "'unchanged' answers the etag of a cache this credential never saw"
    );
}

#[test]
fn a_transport_failure_never_serves_a_cache_from_another_sign_in() {
    let dir = tempfile::tempdir().expect("tempdir");
    let env = env_in(dir.path());
    assert!(
        a_read_whose_sign_in_changed_before_the_call(&env, None, away()).is_err(),
        "the offline identity would be the previous account's"
    );
}

#[test]
fn an_adopted_credential_never_serves_a_cache_from_another_sign_in() {
    let dir = tempfile::tempdir().expect("tempdir");
    let env = env_in(dir.path());
    write_cache(&env, &fixture_body(&["success", "body"]), None, Some(ADA));
    // Two reads in, `load` holds its own credential and has read the
    // cache under it. The request then 401s, and the locked re-read finds
    // somebody else's credential, which the call adopts and retries under
    // rather than refreshing. The answer is theirs; the cache is not.
    let store = SwitchingStore::after(2);
    let fetch = Canned::new(vec![
        ok(401, None, r#"{"error":"invalid_token"}"#),
        ok(503, None, r#"{"error":"down"}"#),
    ]);
    let refused = me::load(&env, &fetch, &store).expect_err("an adopted sign-in is not this one");
    assert!(
        matches!(refused, CoreError::RegistryUnavailable { .. }),
        "an adopted sign-in is a retryable read: got {refused:?}"
    );
    assert_eq!(
        *fetch.calls.borrow(),
        2,
        "the retry under the adopted credential is what this test is about"
    );
}

#[test]
fn a_cache_from_another_sign_in_is_never_served() {
    let dir = tempfile::tempdir().expect("tempdir");
    let env = env_in(dir.path());
    // The previous account's generation outlived its sign-out — a forget
    // that failed, a crash between the two writes, whatever left it
    // there. Somebody else is signed in now and the network is away, so
    // this cache is the only identity on hand.
    write_cache(&env, &fixture_body(&["success", "body"]), None, Some(ADA));
    let store = MemoryStore::signed_in_as(other_account());
    let down = Canned::new(vec![away()]);
    assert!(
        me::load(&env, &down, &store).is_err(),
        "the previous account's name is not this account's offline identity"
    );
}

#[test]
fn a_generation_carrying_no_sign_in_is_never_served() {
    let dir = tempfile::tempdir().expect("tempdir");
    let env = env_in(dir.path());
    // A generation that names no sign-in cannot be shown to belong to
    // this one, so it is another sign-in's as far as the read is
    // concerned.
    write_cache(&env, &fixture_body(&["success", "body"]), None, None);
    let down = Canned::new(vec![away()]);
    assert!(
        me::load(&env, &down, &MemoryStore::signed_in()).is_err(),
        "an unkeyed generation is not this sign-in's identity"
    );
}

#[test]
fn the_cache_names_the_sign_in_without_holding_its_token() {
    let dir = tempfile::tempdir().expect("tempdir");
    let env = env_in(dir.path());
    let store = MemoryStore::signed_in();
    let fetch = Canned::new(vec![ok(200, None, &fixture_body(&["success", "body"]))]);
    me::load(&env, &fetch, &store).expect("load");

    let written = std::fs::read_to_string(env.registry_cache_dir().join("me.cache.json"))
        .expect("the read cached its answer");
    assert!(
        !written.contains("kxr_old"),
        "the cache file is not the keychain"
    );
    assert!(
        written.contains(&kendex_core::hash::hash_bytes(ADA.as_bytes())),
        "the generation names the sign-in it belongs to"
    );
}

#[test]
fn a_sign_in_that_cannot_clear_the_cache_still_reports_success() {
    let dir = tempfile::tempdir().expect("tempdir");
    let env = env_in(dir.path());
    let store = JammingStore {
        inner: MemoryStore::signed_in(),
        env: &env,
    };
    me::commit_sign_in(&env, &store, &other_account())
        .expect("the credential is installed, so the sign-in did not fail");
    assert_eq!(
        store
            .load()
            .expect("load")
            .expect("credential")
            .refresh_token,
        "kxr_other",
        "the sign-in this call reported is the one the machine holds"
    );
}

/// A refresh the server answers, rotating both tokens and keeping the
/// sign-in they belong to.
fn rotation() -> Result<FetchResponse> {
    ok(
        200,
        None,
        r#"{"access_token":"kxa_new","refresh_token":"kxr_new","capabilities":[]}"#,
    )
}

#[test]
fn a_rotation_by_another_call_leaves_the_identity_cache_readable() {
    let dir = tempfile::tempdir().expect("tempdir");
    let env = env_in(dir.path());
    let store = MemoryStore::signed_in();
    let first = Canned::new(vec![ok(200, None, &fixture_body(&["success", "body"]))]);
    me::load(&env, &first, &store).expect("first load");

    // Any authenticated call can rotate, and submissions is one. The
    // tokens move; the sign-in the cached identity belongs to does not.
    let rotating = Canned::new(vec![
        ok(401, None, r#"{"error":"invalid_token"}"#),
        rotation(),
        ok(200, None, r#"{"submissions":[]}"#),
    ]);
    submit::submissions(&rotating, &store).expect("submissions");
    assert_eq!(
        store
            .load()
            .expect("load")
            .expect("credential")
            .refresh_token,
        "kxr_new",
        "the rotation is what makes this the case it is"
    );

    let down = Canned::new(vec![away()]);
    match me::load(&env, &down, &store).expect("offline load") {
        AccountState::Offline { identity, .. } => assert_eq!(identity.name, "Ada Lovelace"),
        other => panic!("the cached identity outlives a rotation, got {other:?}"),
    }
}

#[test]
fn a_rotation_that_then_fails_leaves_the_identity_cache_readable() {
    let dir = tempfile::tempdir().expect("tempdir");
    let env = env_in(dir.path());
    let store = MemoryStore::signed_in();
    let first = Canned::new(vec![ok(200, None, &fixture_body(&["success", "body"]))]);
    me::load(&env, &first, &store).expect("first load");

    // This read rotates and then meets a refused status, so it serves the
    // cache and writes nothing back. What is on disk is still the first
    // read's generation, and it has to survive the rotation that just
    // happened under it.
    let hurt = Canned::new(vec![
        ok(401, None, r#"{"error":"invalid_token"}"#),
        rotation(),
        ok(503, None, r#"{"error":"down"}"#),
    ]);
    assert!(matches!(
        me::load(&env, &hurt, &store).expect("load"),
        AccountState::Offline { .. }
    ));

    let down = Canned::new(vec![away()]);
    match me::load(&env, &down, &store).expect("offline load") {
        AccountState::Offline { identity, .. } => assert_eq!(identity.name, "Ada Lovelace"),
        other => panic!("the next read still has that generation, got {other:?}"),
    }
}
