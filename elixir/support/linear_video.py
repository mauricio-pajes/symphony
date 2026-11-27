"""Private Linear video upload and attachment verification for trusted host workflows."""

import hashlib
import json
import re
from urllib.error import HTTPError
from urllib.parse import urlsplit
from urllib.request import Request, HTTPRedirectHandler, build_opener
from uuid import UUID

LINEAR = "https://api.linear.app/graphql"
ASSET_URL = re.compile(r"https://uploads\.linear\.app/[-/a-zA-Z0-9_]+(?:\.mp4)?")

UPLOAD = """
mutation SymphonyVideoUpload($filename: String!, $size: Int!) {
  fileUpload(filename: $filename, contentType: "video/mp4", size: $size, makePublic: false) {
    success
    uploadFile { uploadUrl assetUrl headers { key value } }
  }
}
"""


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def https_url(value):
    parsed = urlsplit(value)
    return parsed.scheme == "https" and bool(parsed.hostname) and not parsed.username and not parsed.password


def upload(file, key, expected_sha256=None):
    video = file.read_bytes()
    digest = hashlib.sha256(video).hexdigest()
    if expected_sha256 is not None and digest != expected_sha256:
        raise ValueError("The recording changed after verification.")

    opener = build_opener(NoRedirect())
    body = json.dumps({"query": UPLOAD, "variables": {"filename": file.name, "size": len(video)}}).encode()
    with opener.open(Request(LINEAR, data=body, headers={
        "Authorization": key, "Content-Type": "application/json"
    }, method="POST"), timeout=12) as response:
        data = json.load(response)
    payload = (data.get("data") or {}).get("fileUpload")
    if data.get("errors") or not payload or not payload.get("success"):
        raise ValueError("Linear declined the private video upload.")

    upload_file = payload["uploadFile"]
    asset, signed = upload_file["assetUrl"], upload_file["uploadUrl"]
    if not https_url(signed) or not ASSET_URL.fullmatch(asset):
        raise ValueError("Linear returned an unexpected video location.")
    headers = {header["key"]: header["value"] for header in (upload_file["headers"] or [])}
    headers.setdefault("Content-Type", "video/mp4")
    with opener.open(Request(signed, data=video, headers=headers, method="PUT"), timeout=22) as response:
        if response.status not in range(200, 300):
            raise ValueError("The private video upload failed.")

    verify_asset(asset, key, digest, len(video))
    return asset


def verify_asset(asset, key, digest, size):
    # Never forward the Linear API key to a redirect.
    if not ASSET_URL.fullmatch(asset):
        raise ValueError("Linear returned an unexpected asset location.")
    opener = build_opener(NoRedirect())
    try:
        request = Request(asset, headers={"Authorization": key})
        with opener.open(request, timeout=12) as fetched:
            downloaded = fetched.read(size + 1)
    except HTTPError as error:
        with error:
            location = error.headers.get("Location", "")
            if error.code not in (301, 302, 307, 308) or not https_url(location):
                raise ValueError(f"Linear could not read back the private upload (HTTP {error.code}).") from None
        with opener.open(location, timeout=12) as fetched:
            downloaded = fetched.read(size + 1)
    if len(downloaded) != size or hashlib.sha256(downloaded).hexdigest() != digest:
        raise ValueError("The private Linear asset differs from the verified recording.")


def inline_video_markdown(asset):
    """Embed the private MP4 in the Linear editor's native video player."""
    if not ASSET_URL.fullmatch(asset):
        raise ValueError("The inline video must reference a verified Linear upload.")
    return f"![Demo (MP4)]({asset})"


def has_inline_video(description, asset):
    if not ASSET_URL.fullmatch(asset):
        return False
    # Linear serializes its native video node as a file link on readback.
    # Scope that representation to the dedicated section and exact asset.
    video_block = rf"^## Demo\n+!?\[[^\]\n]*\]\({re.escape(asset)}\)$"
    return bool(re.search(video_block, description or "", re.M))


def ensure_attachment(graphql, key, issue_id, intent):
    """Create or confirm the native attachment using a persisted UUID and URL."""
    fields = ("id", "url", "title")
    expected = {field: intent[field] for field in fields}
    if any(str(UUID(value)) != value for value in (issue_id, expected["id"])):
        raise ValueError("The issue and attachment must use canonical UUIDs.")
    if not ASSET_URL.fullmatch(expected["url"]):
        raise ValueError("The attachment must reference a verified Linear upload.")
    query = """query SymphonyReviewAttachment($id: ID!) {
      attachments(first: 1, filter: {id: {eq: $id}}) {
        nodes { id url title issue { id } }
      }
    }"""

    def observed():
        attachments = graphql(key, query, {"id": expected["id"]})["attachments"]["nodes"]
        if not attachments:
            return False
        if attachments != [{**expected, "issue": {"id": issue_id}}]:
            raise ValueError("Linear returned different attachment metadata or issue identity.")
        return True

    if not observed():
        graphql(key, """mutation SymphonyAttachVideo($input: AttachmentCreateInput!) {
          attachmentCreate(input: $input) { success }
        }""", {"input": {**expected, "issueId": issue_id}})
        if not observed():
            raise ValueError("Linear has not confirmed the demo attachment.")
