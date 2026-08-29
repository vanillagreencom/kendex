use super::*;

/// A throwaway minisign keypair signing every document below, generated
/// once so the admitted arm runs the real check rather than a stub standing
/// in for it. The documents carry no path and no URL, so one signature
/// covers each of them on every machine this test runs on.
const TEST_KEY: &str = "dW50cnVzdGVkIGNvbW1lbnQ6IG1pbmlzaWduIHB1YmxpYyBrZXk6IDc1RTYwNzZERUJFMDVFNTcKUldSWFh1RHJiUWZtZFdVSnJYQmd0QnhLVUdUQnN2MWNTR2N6SW9jZ1Z1Q0FoZmlzWDVIeFZJaUkK";

/// What `tools/release-digests` wrote for the 9.9.9 Linux lane, byte for
/// byte, so the shape this parses is the shape a release publishes.
const PUBLISHED: &str = r#"{
  "schema": 1,
  "version": "9.9.9",
  "target": "x86_64-unknown-linux-gnu",
  "command": "aae05017e20c96dd3cd26b1fd324365c2ab53512db82b53362e75f8f553ffaea",
  "app": "d489b792c3c3d6e9633ff28507f2c7da40a24eec743521842ebc283c2c3226ff"
}
"#;
const PUBLISHED_SIGNATURE: &str = "dW50cnVzdGVkIGNvbW1lbnQ6IHNpZ25hdHVyZSBmcm9tIHRhdXJpIHNlY3JldCBrZXkKUlVSWFh1RHJiUWZtZFpxNkg5WFpISHVZL2xIMWR6eWxZN3djZUU2NXpERjVNMjRUMUJlcXlnS1V5dUpDNGsySlpHZkRBUEhiOFN3dFRhVElPaWltajA3RTNpNVk3NndJcXdZPQp0cnVzdGVkIGNvbW1lbnQ6IHRpbWVzdGFtcDoxNzg4MDQyMjM0CWZpbGU6ZGlnZXN0cy14ODZfNjQtdW5rbm93bi1saW51eC1nbnUuanNvbgpzSkg3dGJuMXVNSHIyRkE5enlISnVSRWRNS0xXcWxFVEJ1TkRaSXFsR0ZzZm5LbCtqNThBckYzb1JQVE9UeEk5WExEMXpKYTlSZnl0S2xQUXZxTk9Bdz09Cg==";
/// The bytes `PUBLISHED` names as this release's command and app download.
const COMMAND: &[u8] = b"kendex AppImage bytes";
const APP: &[u8] = b"the linux appimage";

const TARGET: &str = "x86_64-unknown-linux-gnu";
const VERSION: &str = "9.9.9";

/// The same lane's document from an earlier release, signed when it
/// shipped: what a feed claiming 9.9.9 can serve to answer for a release
/// it is not.
const OLDER: &str = r#"{
  "schema": 1,
  "version": "5.0.0",
  "target": "x86_64-unknown-linux-gnu",
  "command": "aae05017e20c96dd3cd26b1fd324365c2ab53512db82b53362e75f8f553ffaea",
  "app": "42c30601103ba7015436bd2feed7b3867ab36ec71e3bece765400efe82a33a08"
}
"#;
const OLDER_SIGNATURE: &str = "dW50cnVzdGVkIGNvbW1lbnQ6IHNpZ25hdHVyZSBmcm9tIHRhdXJpIHNlY3JldCBrZXkKUlVSWFh1RHJiUWZtZFJQSzRNQ0I5Rnk3enVxSkhFb3htZXA0L295SS8ycUhHZnRyWVdjcy9uNTJHczE4M1Q4KzZLL0Vja2tTTFB4SVk4RXRneFRpYWszSTRDbTkyd0RrUEFrPQp0cnVzdGVkIGNvbW1lbnQ6IHRpbWVzdGFtcDoxNzg4MDQyMjM0CWZpbGU6ZGlnZXN0cy14ODZfNjQtdW5rbm93bi1saW51eC1nbnUuanNvbgpVbDlnc2FSQUdFMVY2VWI1Z3NpL3BmMVZ4bDBpTm4wZ05aUUkyaG9ldFByMGhtdGVZTVhpUnVFN0ZuQ01ob0lGR08rMlMrazA1L1luUXQwTjNzMUxDdz09Cg==";

/// Another platform's document for the same release, equally genuine.
const OTHER_TARGET: &str = r#"{
  "schema": 1,
  "version": "9.9.9",
  "target": "aarch64-apple-darwin",
  "command": "ea1eb85cbb8a7c5b0ee438f4924e7825fece13173e9764c8308b1d95bbd7226a",
  "app": "a9c46ccd0a1b1a38b8e7bceb39644bd068f49fd58aeb185491be24326939d567"
}
"#;
const OTHER_TARGET_SIGNATURE: &str = "dW50cnVzdGVkIGNvbW1lbnQ6IHNpZ25hdHVyZSBmcm9tIHRhdXJpIHNlY3JldCBrZXkKUlVSWFh1RHJiUWZtZFF5S1FzZklvb203YVRMdVlqa2NNYm15alFnZVBPcFNvQmdRd3FWOFRFQUxxZENMRk1kOUJlQlcyTUJ4bDdPaWJ2UFZHbHYxcE5ubkRsRUNKR3RpL1FRPQp0cnVzdGVkIGNvbW1lbnQ6IHRpbWVzdGFtcDoxNzg4MDQyMjM0CWZpbGU6ZGlnZXN0cy1hYXJjaDY0LWFwcGxlLWRhcndpbi5qc29uCml0RG1oZWpkZW5iZHBmcERNMHZVNHh3eGFmVTNObHBOZVI5clJwOXFXd2pBQWZGMW9WU0ZkQ3Fici9ib2NhRnFVdzFjcW80NWVPWWJNOWdnNlF0NENBPT0K";

/// Documents this key really signed whose contents are not a statement
/// this build can act on. Each is signed, so each reaches the reading that
/// refuses it rather than stopping at the signature.
const UNREADABLE: &[(&str, &str, &str)] = &[
    (
        r#"{"schema":2,"version":"9.9.9","target":"x86_64-unknown-linux-gnu","command":"aae05017e20c96dd3cd26b1fd324365c2ab53512db82b53362e75f8f553ffaea","app":"aae05017e20c96dd3cd26b1fd324365c2ab53512db82b53362e75f8f553ffaea"}"#,
        "dW50cnVzdGVkIGNvbW1lbnQ6IHNpZ25hdHVyZSBmcm9tIHRhdXJpIHNlY3JldCBrZXkKUlVSWFh1RHJiUWZtZFJrRXhhM2h0WWZia2VoYUh3SXgwcEs0NUxGMURaWjBaaWlLS0N5bmVQNEJ1VElKc0JNZHZPQW8xaFZZREpkS3p2TUVpbVJQVU5iSTVqaWRRUmhtTkFjPQp0cnVzdGVkIGNvbW1lbnQ6IHRpbWVzdGFtcDoxNzg4MDQyMzM0CWZpbGU6c2NoZW1hLmpzb24KRVJpQWxCaGpxeTdGNHlYL2I5eGdoaGdHWk94NDBlZ1huNS9NN1V5Vnk2L0NTd2VTUEpmc1hTaXN4SkxDdkVKcUtkVFU1QVFMa200elJ6T1pjdlVVQnc9PQo=",
        "schema 2 is not supported",
    ),
    (
        r#"{"schema":1,"version":"9.9.9","target":"","command":"aae05017e20c96dd3cd26b1fd324365c2ab53512db82b53362e75f8f553ffaea","app":"aae05017e20c96dd3cd26b1fd324365c2ab53512db82b53362e75f8f553ffaea"}"#,
        "dW50cnVzdGVkIGNvbW1lbnQ6IHNpZ25hdHVyZSBmcm9tIHRhdXJpIHNlY3JldCBrZXkKUlVSWFh1RHJiUWZtZFdsZ2x3SjdKQ0lFTVpPMkVZNUdXSWlzNENaQ050QnRRYXlGeTBMWEpDZlFmRWQ3TTV4dGhIZUhhQ0tSYk5ac1FVQ1d6WDNRaUkxSm5odGVCdjI2dmdZPQp0cnVzdGVkIGNvbW1lbnQ6IHRpbWVzdGFtcDoxNzg4MDQyMzM0CWZpbGU6dGFyZ2V0Lmpzb24KZDhUbmxYNWllQTFEOEVPaU5rK3lUbmVmRFp2bmtGYklQaHhIL3hYR0JhWGhTRTJRVlhZNjlkbnd0bVN2Umgva2tURVpndzczWkxJd0FwVW5kK1RLRGc9PQo=",
        "name a target of 0 bytes",
    ),
    (
        r#"{"schema":1,"version":"9.9.9","target":"x86_64-unknown-linux-gnu","command":"not a digest","app":"aae05017e20c96dd3cd26b1fd324365c2ab53512db82b53362e75f8f553ffaea"}"#,
        "dW50cnVzdGVkIGNvbW1lbnQ6IHNpZ25hdHVyZSBmcm9tIHRhdXJpIHNlY3JldCBrZXkKUlVSWFh1RHJiUWZtZGNjMVhlcHpnOUlRNEFsUDNDMG5LdmFmMm4rMGFPbm03bGR2R1BRbHpDTjV0bEN6OEc4dlBlRUp0YjRRTTM3dk5zWVhCZ3dTUm8wWitBVWg5WTNXM0FrPQp0cnVzdGVkIGNvbW1lbnQ6IHRpbWVzdGFtcDoxNzg4MDQyMzM0CWZpbGU6ZGlnZXN0Lmpzb24KekVPZGxDWmh1NXFJN1RwUTRrUElxT0JvQlgxVzNZaXJ1UlFHMlRwRzNKdjhQNnlta01qSjN3YjNHamxISUExaERZVS96dVJydE5WZDNBK3cyclVlQ1E9PQo=",
        "digest for the command is not 64 hex characters",
    ),
    (
        "a release published a page, not a document",
        "dW50cnVzdGVkIGNvbW1lbnQ6IHNpZ25hdHVyZSBmcm9tIHRhdXJpIHNlY3JldCBrZXkKUlVSWFh1RHJiUWZtZFR1UUdwOGhobmlyaldFWGJNcGJRZ01jVGE0dUxOLzRkZGtsUnkrQ0d1K2JSVXB6MlRkMkg0REEwUTB4VWlzaUJmVnA1a1ZQQ01mczFyUWRkcW83UndBPQp0cnVzdGVkIGNvbW1lbnQ6IHRpbWVzdGFtcDoxNzg4MDQyMzM0CWZpbGU6cHJvc2UuanNvbgozT3RDVVZGeXNaMEI5MUhndStVQzZmTGJFeEM0azRFUEhPT3RpNnZJWDFLd01KRFlYdk9RQlFsZ0pIc3UxVVp6azJHVEo1U29QaFZ2RXdjVTlOdCtBdz09Cg==",
        "not readable",
    ),
];

fn read(document: &str, signature: &str) -> Result<ReleaseDigests> {
    ReleaseDigests::for_release(
        TEST_KEY,
        document.as_bytes(),
        signature.as_bytes(),
        VERSION,
        TARGET,
    )
}

/// The admitted arm, and the one every refusal below is read against: the
/// release's own document for the release and target being asked about.
#[test]
fn the_release_own_document_for_this_target_is_read() {
    let digests = read(PUBLISHED, PUBLISHED_SIGNATURE).expect("the release signed this document");
    assert_eq!(digests.schema, DIGESTS_SCHEMA);
    assert_eq!(digests.version, VERSION);
    assert_eq!(digests.target, TARGET);
    digests
        .verify_command(COMMAND)
        .expect("the published command");
    digests.verify_app(APP).expect("the published app download");
}

/// The whole defect in one assertion: a genuine signature over another
/// release's document, or another platform's, does not answer for the one
/// asked for. Both are real signatures under the pinned key, so what
/// refuses them is the binding and nothing else.
#[test]
fn a_genuinely_signed_document_for_another_release_or_target_is_refused() {
    let older = read(OLDER, OLDER_SIGNATURE).unwrap_err().to_string();
    assert!(older.contains("the feed offers 9.9.9"), "{older}");
    assert!(older.contains("5.0.0"), "{older}");

    let elsewhere = read(OTHER_TARGET, OTHER_TARGET_SIGNATURE)
        .unwrap_err()
        .to_string();
    assert!(elsewhere.contains("aarch64-apple-darwin"), "{elsewhere}");
}

/// A document nothing signed is not the release's, whatever it says, and
/// neither is one whose bytes moved after it was signed.
#[test]
fn a_document_the_release_key_does_not_cover_is_refused() {
    let tampered = PUBLISHED.replace("9.9.9", "9.9.8");
    for (document, signature) in [
        (PUBLISHED, ""),
        (PUBLISHED, "not a signature"),
        (tampered.as_str(), PUBLISHED_SIGNATURE),
    ] {
        let refused = ReleaseDigests::for_release(
            TEST_KEY,
            document.as_bytes(),
            signature.as_bytes(),
            "9.9.8",
            TARGET,
        );
        assert!(refused.is_err(), "{document} under '{signature}'");
    }
}

/// Signed and still unreadable: each of these reaches the reading of the
/// document, so a green pass here is the reading refusing, not the
/// signature check standing in for it.
#[test]
fn a_signed_document_this_build_cannot_act_on_is_refused() {
    for (document, signature, why) in UNREADABLE {
        let refused = read(document, signature).unwrap_err().to_string();
        assert!(refused.contains(why), "{refused}");
    }
}

/// The size cap is read before anything else, so a body too large to be a
/// lane's document never reaches the signature check.
#[test]
fn a_body_larger_than_a_document_is_refused_unread() {
    let huge = vec![b' '; MAX_DIGESTS_BYTES + 1];
    let refused = ReleaseDigests::for_release(TEST_KEY, &huge, b"", VERSION, TARGET)
        .unwrap_err()
        .to_string();
    assert!(refused.contains("the limit is"), "{refused}");
}

/// Bytes the release did not publish for this half are refused even when
/// the document is the release's own — which is the case where a signature
/// is genuine over an artifact this release never named.
#[test]
fn bytes_this_release_did_not_publish_are_refused() {
    let digests = read(PUBLISHED, PUBLISHED_SIGNATURE).expect("the release signed this document");
    for bytes in [APP, b"an older kendex, signed when it shipped".as_slice()] {
        let refused = digests.verify_command(bytes).unwrap_err().to_string();
        assert!(
            refused.contains("the kendex command hashes to"),
            "{refused}"
        );
        assert!(refused.contains(&digests.command), "{refused}");
    }
    let refused = digests.verify_app(COMMAND).unwrap_err().to_string();
    assert!(refused.contains("the desktop app download"), "{refused}");
}

/// The document is found beside the manifest the channel served, never at
/// a name the feed supplied.
#[test]
fn the_document_is_a_sibling_of_the_manifest_it_judges() {
    use crate::update_channel::{PRERELEASE_FEED_URL, RELEASE_FEED_URL, RELEASE_MANIFEST_URL};
    assert_eq!(
        release_digests_url(RELEASE_FEED_URL, TARGET).unwrap(),
        "https://github.com/vanillagreencom/kendex/releases/latest/download/digests-x86_64-unknown-linux-gnu.json"
    );
    assert_eq!(
        release_digests_url(RELEASE_MANIFEST_URL, TARGET).unwrap(),
        release_digests_url(RELEASE_FEED_URL, TARGET).unwrap()
    );
    assert_eq!(
        release_digests_url(PRERELEASE_FEED_URL, TARGET).unwrap(),
        "https://github.com/vanillagreencom/kendex/releases/download/prerelease/digests-x86_64-unknown-linux-gnu.json"
    );
    assert_eq!(
        release_digests_url("file:///tmp/fixture/feed.json", TARGET).unwrap(),
        "file:///tmp/fixture/digests-x86_64-unknown-linux-gnu.json"
    );
}

/// A target is a build name, so nothing that could steer the read
/// elsewhere is one.
#[test]
fn a_target_that_is_not_a_build_name_names_no_document() {
    for target in ["", "../../../etc/passwd", "x86_64/../..", &"t".repeat(129)] {
        assert!(
            release_digests_url(RELEASE_FEED_URL_FIXTURE, target).is_err(),
            "{target}"
        );
    }
    assert!(release_digests_url("digests", TARGET).is_err());
}

const RELEASE_FEED_URL_FIXTURE: &str = "https://example.test/download/feed.json";
