#!/usr/bin/env python3
"""Draft and send a user-approved request through the YouTube Data API."""

import argparse
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener


API = "https://www.googleapis.com/youtube/v3/"
UPLOAD = "https://www.googleapis.com/upload/youtube/v3/videos"


class Refusal(Exception):
    def __init__(self, code):
        self.code = code


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def setting(name):
    value = os.environ.get(name, "").strip()
    if not value:
        raise Refusal("setting-missing:" + name)
    return value


def file_digest(stream):
    digest = hashlib.sha256()
    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
        digest.update(chunk)
    return digest.hexdigest()


def request_digest(draft):
    # Paths locate local bytes. Approval binds their digest, not a machine's path.
    return hashlib.sha256(canonical({key: value for key, value in draft.items()
                                    if key not in ("video_path", "request_sha256", "approval_record")})).hexdigest()


def draft_request(args):
    draft = {"issue": args.issue, "channel_id": setting("YOUTUBE_CHANNEL_ID")}
    if args.command == "draft-upload":
        with Path(args.video).open("rb") as stream:
            video_hash = file_digest(stream)
        draft.update(operation="upload", video_path=str(Path(args.video).resolve()), video_sha256=video_hash,
                     body={"snippet": {"title": args.title, "description": args.description,
                                       "categoryId": args.category},
                           "status": {"privacyStatus": args.privacy, "containsSyntheticMedia": True,
                                      "selfDeclaredMadeForKids": args.made_for_kids == "yes"}})
    elif args.parent_id:
        draft.update(operation="reply", body={"snippet": {"parentId": args.parent_id, "textOriginal": args.text}})
    else:
        draft.update(operation="comment", body={"snippet": {"channelId": args.target_channel_id or draft["channel_id"],
                     "videoId": args.video_id, "topLevelComment": {"snippet": {"textOriginal": args.text}}}})
    draft["request_sha256"] = request_digest(draft)
    draft["approval_record"] = {"youtube_publish": {"issue": args.issue, "decision": "yes",
                                                   "request_sha256": draft["request_sha256"]}}
    return draft


def tracker_read(resource, issue):
    linear = Path(__file__).resolve().parents[2] / "linear/scripts/linear.sh"
    bash = shutil.which("bash")
    if not linear.is_file() or not bash:
        raise Refusal("tracker-dependency-missing")
    # The Linear owner loads consumer settings and credentials from the project.
    names = ("PATH", "HOME", "USER", "SYSTEMROOT", "TEMP", "TMP", "KENDEX_ENV_FILE",
             "LINEAR_API_KEY", "LINEAR_APP_TOKEN", "LINEAR_CLIENT_ID", "LINEAR_CLIENT_SECRET")
    result = subprocess.run([bash, str(linear), resource, "get" if resource == "issues" else "list", issue],
                            env={name: os.environ[name] for name in names if name in os.environ},
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120, check=False)
    if result.returncode:
        raise Refusal("tracker-read-failed")
    return json.loads(result.stdout)


def require_approval(draft):
    issue = tracker_read("issues", draft["issue"])
    if issue.get("id") != draft["issue"]:
        raise Refusal("tracker-item-mismatch")
    owner = setting("YOUTUBE_APPROVER_EMAIL").casefold()
    expected = {"youtube_publish": {"issue": draft["issue"], "decision": "yes",
                                    "request_sha256": request_digest(draft)}}
    decisions = []
    for comment in tracker_read("comments", draft["issue"]):
        if str(comment.get("user_email", "")).casefold() != owner or not comment.get("id"):
            continue
        try:
            record = json.loads(comment.get("body", ""))
        except (ValueError, TypeError):
            continue
        decision = record.get("youtube_publish", {}) if isinstance(record, dict) else {}
        if (isinstance(decision, dict) and decision.get("issue") == draft["issue"]
                and decision.get("request_sha256") == expected["youtube_publish"]["request_sha256"]):
            # Linear emits both timestamps. Edits change the decision's time, not its array position.
            try:
                times = [datetime.fromisoformat(comment[key].replace("Z", "+00:00"))
                         for key in ("updated_at", "created_at")]
                if any(value.utcoffset() is None for value in times):
                    raise ValueError("timezone missing")
                decisions.append((max(times), record, comment["id"]))
            except (KeyError, TypeError, ValueError, AttributeError):
                raise Refusal("approval-required") from None
    if not decisions:
        raise Refusal("approval-required")
    latest_time = max(decision[0] for decision in decisions)
    latest = [decision for decision in decisions if decision[0] == latest_time]
    if len(latest) != 1 or latest[0][1] != expected:
        raise Refusal("approval-required")
    return latest[0][2]


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        # An upload response must not send the consumer's token to another host.
        raise Refusal("api-redirect-refused")


class YouTube:
    def __init__(self):
        self.token = setting("YOUTUBE_ACCESS_TOKEN")
        self.opener = build_opener(NoRedirect())

    def request(self, method, url, data=None, headers=None):
        request = Request(url, data=data, method=method,
                          headers={"Authorization": "Bearer " + self.token, **(headers or {})})
        try:
            with self.opener.open(request, timeout=120) as response:
                return dict(response.headers), response.read()
        except HTTPError as error:
            # Do not print upstream bodies or session URLs, which can contain private data.
            raise Refusal("api-http:" + str(error.code)) from None
        except (URLError, TimeoutError, OSError):
            raise Refusal("api-outcome-uncertain") from None


def send(draft):
    if draft["channel_id"] != setting("YOUTUBE_CHANNEL_ID"):
        raise Refusal("channel-mismatch")
    if draft["request_sha256"] != request_digest(draft):
        raise Refusal("draft-changed")
    operation = draft["operation"]
    if operation not in ("upload", "comment", "reply"):
        raise Refusal("operation-unknown")
    if operation == "upload" and draft["body"]["status"].get("containsSyntheticMedia") is not True:
        raise Refusal("disclosure-required")
    approval = require_approval(draft)
    api = YouTube()
    _, raw = api.request("GET", API + "channels?" + urlencode({"part": "id", "mine": "true"}))
    if [item["id"] for item in json.loads(raw)["items"]] != [draft["channel_id"]]:
        raise Refusal("oauth-channel-mismatch")
    if operation == "upload":
        # Snapshot the media before checking its approval digest so changed bytes cannot be sent.
        with tempfile.TemporaryFile() as media:
            with Path(draft["video_path"]).open("rb") as source:
                shutil.copyfileobj(source, media)
            size = media.tell()
            media.seek(0)
            if file_digest(media) != draft["video_sha256"]:
                raise Refusal("video-changed")
            media.seek(0)
            headers, _ = api.request("POST", UPLOAD + "?uploadType=resumable&part=snippet,status",
                                     canonical(draft["body"]), {"Content-Type": "application/json; charset=UTF-8",
                                     "X-Upload-Content-Length": str(size), "X-Upload-Content-Type": "application/octet-stream"})
            location = next((value for key, value in headers.items() if key.lower() == "location"), "")
            target = urlsplit(location)
            if (target.scheme != "https" or target.netloc != "www.googleapis.com"
                    or target.path != "/upload/youtube/v3/videos"):
                raise Refusal("upload-location-invalid")
            _, raw = api.request("PUT", location, media,
                                 {"Content-Length": str(size), "Content-Type": "application/octet-stream"})
    else:
        endpoint = "commentThreads" if operation == "comment" else "comments"
        _, raw = api.request("POST", API + endpoint + "?part=snippet", canonical(draft["body"]),
                             {"Content-Type": "application/json; charset=UTF-8"})
    resource = json.loads(raw)
    if not resource.get("id"):
        raise Refusal("api-resource-missing")
    return {"resource_id": resource["id"], "approval_comment_id": approval,
            "privacy_status": resource.get("status", {}).get("privacyStatus")}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    upload = commands.add_parser("draft-upload")
    for name in ("issue", "video", "title", "description", "category"):
        upload.add_argument("--" + name, required=True)
    upload.add_argument("--privacy", choices=("public", "private", "unlisted"), required=True)
    upload.add_argument("--made-for-kids", choices=("yes", "no"), required=True)
    comment = commands.add_parser("draft-comment")
    for name in ("issue", "video-id", "text"):
        comment.add_argument("--" + name, required=True)
    comment.add_argument("--parent-id")
    comment.add_argument("--target-channel-id", help="Channel that owns the target video; defaults to the consumer's channel")
    publish = commands.add_parser("publish")
    publish.add_argument("--draft", required=True)
    args = parser.parse_args()
    try:
        if args.command == "publish":
            with Path(args.draft).open(encoding="utf-8") as source:
                output = send(json.load(source))
        else:
            output = draft_request(args)
        print(json.dumps(output, ensure_ascii=False))
    except Refusal as error:
        print(json.dumps({"error": error.code}), file=sys.stderr)
        return 1
    except (OSError, ValueError, KeyError, TypeError, subprocess.TimeoutExpired):
        print(json.dumps({"error": "input-or-dependency-invalid"}), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
