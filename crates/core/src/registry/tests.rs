use super::*;

#[test]
fn production_release_feed_plan_bounds_https_redirects_and_allows_file_fixtures() {
    let args = ReleaseFeedFetch::request_args(
        "https://github.com/example/latest/feed.json",
        Some("old-etag"),
    );
    assert!(args.windows(2).any(|pair| pair == ["--max-redirs", "3"]));
    assert!(
        args.windows(2)
            .any(|pair| pair == ["--proto-redir", "=https"])
    );
    assert!(args.iter().any(|arg| arg == "--location"));
    assert!(
        args.windows(2)
            .any(|pair| pair == ["-H", "If-None-Match: old-etag"])
    );

    let fixture = ReleaseFeedFetch::request_args("file:///fixture/feed.json", None);
    assert!(
        fixture
            .windows(2)
            .any(|pair| pair == ["--proto", "=https,file"])
    );
    assert!(
        fixture
            .windows(2)
            .any(|pair| pair == ["--proto-redir", "=https"])
    );
}

#[test]
fn redirected_headers_yield_the_final_response() {
    let response = parse_http_response(
        b"HTTP/1.1 302 Found\r\nLocation: https://example.test/feed\r\n\r\n\
          HTTP/2 200\r\nETag: final\r\n\r\n{\"schema\":1}",
    )
    .unwrap();
    assert_eq!(response.status, 200);
    assert_eq!(response.etag.as_deref(), Some("final"));
    assert_eq!(response.body, br#"{"schema":1}"#);
}

#[test]
fn release_feed_file_fixture_returns_a_plain_success() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("feed.json");
    std::fs::write(&path, br#"{"version":"5.0.1","assets":{}}"#).unwrap();
    let response = ReleaseFeedFetch
        .get(&format!("file://{}", path.display()), Some("ignored"))
        .unwrap();
    assert_eq!(response.status, 200);
    assert_eq!(response.etag, None);
    assert_eq!(response.body, br#"{"version":"5.0.1","assets":{}}"#);
}
