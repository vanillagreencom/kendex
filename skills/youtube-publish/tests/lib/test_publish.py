"""Execute the publishing path against recorded API shapes, without a network."""

import argparse
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "scripts/youtube-publish.py"
FIXTURE = json.loads((ROOT / "tests/fixtures/api.json").read_text(encoding="utf-8"))


def load(path):
    spec = importlib.util.spec_from_file_location("youtube_publish", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Response(io.BytesIO):
    def __init__(self, body, headers):
        super().__init__(json.dumps(body).encode() if body is not None else b"")
        self.headers = headers


class RecordedAPI:
    def __init__(self, operation):
        self.operation = operation
        self.requests = []
        self.channels = FIXTURE["channels_response"]
        self.location = FIXTURE["upload_headers"]
        self.error = None

    def open(self, request, timeout):
        data = request.data
        if hasattr(data, "read"):
            data = data.read()
        self.requests.append((request.method, request.full_url, data, dict(request.headers)))
        if self.error:
            raise self.error
        if request.method == "GET":
            return Response(self.channels, {})
        if self.operation == "upload" and request.method == "POST":
            return Response(None, self.location)
        return Response(FIXTURE[self.operation + "_response"], {})


class PublishTests(unittest.TestCase):
    def setUp(self):
        self.module = load(SOURCE)
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.video = Path(self.scratch.name) / "video.bin"
        self.video.write_bytes(bytes.fromhex(FIXTURE["video_hex"]))
        self.env = patch.dict(os.environ, {"YOUTUBE_CHANNEL_ID": FIXTURE["channel"],
                             "YOUTUBE_APPROVER_EMAIL": FIXTURE["user_email"],
                             "YOUTUBE_ACCESS_TOKEN": "fixture-token"}, clear=True)
        self.env.start()
        self.addCleanup(self.env.stop)

    def draft(self, operation, module=None):
        args = argparse.Namespace(command="draft-upload" if operation == "upload" else "draft-comment",
                                  issue=FIXTURE["issue"], video=str(self.video), title="Product demo",
                                  description="Synthetic demo", category="22", privacy="unlisted",
                                  made_for_kids="no", text="Thanks for the question.", video_id="fixture-video",
                                  parent_id="fixture-parent" if operation == "reply" else None, target_channel_id=None)
        return (module or self.module).draft_request(args)

    def approval(self, draft):
        return {"id": "fixture-approval", "user_email": FIXTURE["user_email"],
                "created_at": "2026-10-11T10:00:00.000Z", "updated_at": "2026-10-11T10:00:00.000Z",
                "body": json.dumps(draft["approval_record"])}

    def run_send(self, module, draft, comments, api):
        def tracker(resource, issue):
            self.assertEqual(issue, FIXTURE["issue"])
            return {"id": issue} if resource == "issues" else comments
        with patch.object(module, "tracker_read", side_effect=tracker), patch.object(module, "build_opener", return_value=api):
            return module.send(draft)

    def assert_refused(self, module, draft, comments, api, code):
        with self.assertRaises(module.Refusal) as caught:
            self.run_send(module, draft, comments, api)
        self.assertEqual(caught.exception.code, code)

    def assert_no_approval_no_write(self, module):
        for operation in ("upload", "comment", "reply"):
            draft = self.draft(operation, module)
            api = RecordedAPI(operation)
            self.assert_refused(module, draft, [], api, "approval-required")
            self.assertEqual(api.requests, [])

    def test_drafts_and_no_approval_make_no_request(self):
        self.assert_no_approval_no_write(self.module)
        for operation in ("upload", "comment", "reply"):
            self.assertEqual(self.draft(operation)["body"], FIXTURE[operation + "_body"])

    def test_approved_request_matches_recorded_api(self):
        for operation, endpoint in (("upload", "/upload/youtube/v3/videos"),
                                    ("comment", "/youtube/v3/commentThreads"), ("reply", "/youtube/v3/comments")):
            with self.subTest(operation=operation):
                draft = self.draft(operation)
                api = RecordedAPI(operation)
                result = self.run_send(self.module, draft, [self.approval(draft)], api)
                self.assertEqual(result["resource_id"], FIXTURE[operation + "_response"]["id"])
                self.assertEqual(result["approval_comment_id"], "fixture-approval")
                method, url, data, headers = api.requests[1]
                self.assertEqual(method, "POST")
                self.assertEqual(url.split("?", 1)[0], "https://www.googleapis.com" + endpoint)
                self.assertEqual(json.loads(data), FIXTURE[operation + "_body"])
                self.assertEqual(headers["Authorization"], "Bearer fixture-token")
                if operation == "upload":
                    self.assertEqual(api.requests[2][0], "PUT")
                    self.assertEqual(api.requests[2][2], bytes.fromhex(FIXTURE["video_hex"]))
                    self.assertEqual(result["privacy_status"], "private")
                yes = self.approval(draft)
                no = copy.deepcopy(yes)
                no.update(id="fixture-old-refusal", created_at="2026-10-11T09:00:00.000Z",
                          updated_at="2026-10-11T09:00:00.000Z")
                record = json.loads(no["body"])
                record["youtube_publish"]["decision"] = "no"
                no["body"] = json.dumps(record)
                for comments in ([yes, no], [no, yes]):
                    api = RecordedAPI(operation)
                    result = self.run_send(self.module, draft, comments, api)
                    self.assertEqual(result["approval_comment_id"], "fixture-approval")
                    self.assertEqual(result["resource_id"], FIXTURE[operation + "_response"]["id"])

    def test_approval_identity_and_exact_request(self):
        draft = self.draft("comment")
        for change in ("user", "decision", "issue", "digest", "malformed", "timezone"):
            with self.subTest(change=change):
                comment = self.approval(draft)
                record = json.loads(comment["body"])
                if change == "user":
                    comment["user_email"] = "agent@example.invalid"
                elif change == "malformed":
                    comment["body"] = "not JSON"
                elif change == "timezone":
                    comment.update(created_at="2026-10-11T10:00:00", updated_at="2026-10-11T10:00:00")
                else:
                    key = {"decision": "decision", "issue": "issue", "digest": "request_sha256"}[change]
                    record["youtube_publish"][key] = "different"
                if change != "malformed":
                    comment["body"] = json.dumps(record)
                api = RecordedAPI("comment")
                self.assert_refused(self.module, draft, [comment], api, "approval-required")
                self.assertEqual(api.requests, [])

    def test_tracker_read_failure_makes_no_api_request(self):
        draft = self.draft("comment")
        api = RecordedAPI("comment")
        with patch.object(self.module, "tracker_read", side_effect=self.module.Refusal("tracker-read-failed")), patch.object(self.module, "build_opener", return_value=api):
            with self.assertRaises(self.module.Refusal) as caught:
                self.module.send(draft)
        self.assertEqual(caught.exception.code, "tracker-read-failed")
        self.assertEqual(api.requests, [])

    def assert_latest_decision_required(self, module):
        rows = (
            ("later", "2026-10-11T11:00:00.000Z", "2026-10-11T11:00:00.000Z"),
            ("edited", "2026-10-11T09:00:00.000Z", "2026-10-11T11:00:00.000Z"),
            ("tie", "2026-10-11T10:00:00.000Z", "2026-10-11T10:00:00.000Z"),
            ("missing", None, "2026-10-11T11:00:00.000Z"),
            ("invalid", "invalid", "2026-10-11T11:00:00.000Z"),
            ("timezone missing", "2026-10-11T11:00:00", "2026-10-11T11:00:00"),
        )
        for operation in ("upload", "comment", "reply"):
            for name, created, updated in rows:
                draft = self.draft(operation, module)
                yes = self.approval(draft)
                no = copy.deepcopy(yes)
                no.update(id="fixture-refusal", created_at=created, updated_at=updated)
                record = json.loads(no["body"])
                record["youtube_publish"]["decision"] = "no"
                no["body"] = json.dumps(record)
                for comments in ([yes, no], [no, yes]):
                    api = RecordedAPI(operation)
                    self.assert_refused(module, draft, comments, api, "approval-required")
                    self.assertEqual(api.requests, [], (operation, name))

    def test_later_denial_supersedes_approval(self):
        self.assert_latest_decision_required(self.module)

    def test_guards_and_their_must_fail_controls(self):
        # Each mutation keeps the matched code in a disposable source copy outside the worktree.
        rows = (
            ("approval-required", 'approval = require_approval(draft)', 'approval = "bypassed"'),
            ("approval-order", 'latest_time = max(decision[0] for decision in decisions)', 'latest_time = decisions[0][0]'),
            ("approval-ambiguity", 'len(latest) != 1', 'False'),
            ("approval-timestamp", 'except (KeyError, TypeError, ValueError, AttributeError):\n                raise Refusal("approval-required") from None',
             'except (KeyError, TypeError, ValueError, AttributeError):\n                continue'),
            ("approval-timezone", 'if any(value.utcoffset() is None for value in times):', 'if False:'),
            ("channel-mismatch", 'if draft["channel_id"] != setting("YOUTUBE_CHANNEL_ID"):', 'if False:'),
            ("draft-changed", 'if draft["request_sha256"] != request_digest(draft):', 'if False:'),
            ("disclosure-required", 'if operation == "upload" and draft["body"]["status"].get("containsSyntheticMedia") is not True:', 'if False:'),
            ("oauth-channel-mismatch", 'if [item["id"] for item in json.loads(raw)["items"]] != [draft["channel_id"]]:', 'if False:'),
            ("video-changed", 'if file_digest(media) != draft["video_sha256"]:', 'if False:'),
            ("upload-location-invalid", 'target.scheme != "https"', 'False'),
        )
        source = SOURCE.read_text(encoding="utf-8")
        for code, old, new in rows:
            with self.subTest(code=code):
                self.assertEqual(source.count(old), 1)
                path = Path(self.scratch.name) / "mutant.py"
                path.write_text(source.replace(old, new), encoding="utf-8")
                mutant = load(path)
                if code == "approval-required":
                    with self.assertRaises(AssertionError):
                        self.assert_no_approval_no_write(mutant)
                    continue
                if code in ("approval-order", "approval-ambiguity", "approval-timestamp"):
                    with self.assertRaises(AssertionError):
                        self.assert_latest_decision_required(mutant)
                    continue
                if code == "approval-timezone":
                    draft = self.draft("comment")
                    comment = self.approval(draft)
                    comment.update(created_at="2026-10-11T10:00:00", updated_at="2026-10-11T10:00:00")
                    with self.assertRaises(AssertionError):
                        self.assert_refused(mutant, draft, [comment], RecordedAPI("comment"), "approval-required")
                    continue
                draft = self.draft("upload")
                api = RecordedAPI("upload")
                if code == "channel-mismatch":
                    draft["channel_id"] = "another-channel"
                elif code == "draft-changed":
                    draft["request_sha256"] = "changed"
                elif code == "disclosure-required":
                    draft["body"]["status"]["containsSyntheticMedia"] = False
                elif code == "oauth-channel-mismatch":
                    api.channels = {"items": [{"id": "another-channel"}]}
                elif code == "video-changed":
                    self.video.write_bytes(b"changed")
                elif code == "upload-location-invalid":
                    api.location = {"Location": FIXTURE["upload_headers"]["Location"].replace("https:", "http:")}
                if code != "draft-changed":
                    draft["request_sha256"] = self.module.request_digest(draft)
                draft["approval_record"]["youtube_publish"]["request_sha256"] = self.module.request_digest(draft)
                comments = [self.approval(draft)]
                self.assert_refused(self.module, draft, comments, api, code)
                with self.assertRaises(AssertionError):
                    self.assert_refused(mutant, draft, comments, copy.deepcopy(api), code)
                self.video.write_bytes(bytes.fromhex(FIXTURE["video_hex"]))


if __name__ == "__main__":
    unittest.main()
