"""Bounded, fixed-origin X directory reads."""

from __future__ import annotations

import re
from datetime import UTC, datetime
from urllib.parse import urlsplit

import httpx

from ..credentials import CredentialError
from ..transport import provider_client

ORIGIN = "https://api.x.com"
_HANDLE = re.compile(r"[A-Za-z0-9_]{1,15}")
_REMOTE = re.compile(r"[1-9][0-9]{0,18}")
_PAGE = re.compile(r"[A-Za-z0-9_+/.=-]{1,256}")


class XReadError(CredentialError):
    def __init__(self, kind, *, units=None, retry_after=None):
        super().__init__(kind)
        self.kind, self.units, self.retry_after = kind, units, retry_after


def handle(value):
    if not isinstance(value, str):
        raise XReadError("invalid_handle", units=0)
    value = value.strip().removeprefix("@")
    if not _HANDLE.fullmatch(value):
        raise XReadError("invalid_handle", units=0)
    return value.lower()


def remote_id(value):
    if not isinstance(value, str) or not _REMOTE.fullmatch(value):
        raise XReadError("invalid_remote_id", units=0)
    return value


def list_id(value):
    if isinstance(value, str):
        value = value.strip()
        if _REMOTE.fullmatch(value):
            return value
        try:
            parsed = urlsplit(value)
        except ValueError:
            raise XReadError("invalid_list", units=0) from None
        match = re.fullmatch(r"/i/lists/([1-9][0-9]{0,18})/?", parsed.path)
        if (
            parsed.scheme == "https"
            and parsed.netloc.lower() in {"x.com", "www.x.com", "twitter.com", "www.twitter.com"}
            and not (parsed.query or parsed.fragment)
            and match
        ):
            return match[1]
    raise XReadError("invalid_list", units=0)


def _user(value):
    if (
        not isinstance(value, dict)
        or not isinstance(value.get("id"), str)
        or not _REMOTE.fullmatch(value["id"])
        or not isinstance(value.get("username"), str)
        or not _HANDLE.fullmatch(value["username"])
        or type(value.get("protected")) is not bool
    ):
        raise XReadError("malformed_response", units=1)
    return dict(remote_id=value["id"], handle=value["username"], protected=value["protected"])


def _post(data):
    if not isinstance(data, dict):
        raise ValueError()
    identity, author = remote_id(data.get("id")), remote_id(data.get("author_id"))
    raw_date, text = data.get("created_at"), data.get("text")
    sensitive, withheld = data.get("possibly_sensitive"), data.get("withheld")
    references = data.get("referenced_posts", [])
    if (
        not isinstance(raw_date, str)
        or not 1 <= len(raw_date) <= 64
        or not isinstance(text, str)
        or not 1 <= len(text) <= 32_768
        or ("possibly_sensitive" in data and type(sensitive) is not bool)
        or ("withheld" in data and not isinstance(withheld, dict))
        or not isinstance(references, list)
        or len(references) > 5
    ):
        raise ValueError()
    published = datetime.fromisoformat(raw_date.replace("Z", "+00:00"))
    if published.tzinfo is None or published.utcoffset() is None:
        raise ValueError()
    normalized = []
    for ref in references:
        if not isinstance(ref, dict) or ref.get("type") not in {
            "quoted",
            "replied_to",
            "retweeted",
        }:
            raise ValueError()
        item = {"type": ref["type"], "id": remote_id(ref.get("id"))}
        if item["id"] == identity or item in normalized:
            raise ValueError()
        normalized.append(item)
    return dict(
        id=identity,
        author_id=author,
        published_at=published.astimezone(UTC).isoformat(),
        text=text,
        references=normalized,
        sensitive=sensitive,
        withheld=withheld is not None,
    )


class XClient:
    def __init__(self, token, *, client=None):
        if (
            not isinstance(token, str)
            or not 1 <= len(token) <= 4096
            or any(not 33 <= ord(char) <= 126 for char in token)
        ):
            raise XReadError("credential_unavailable", units=0)
        self.token = token
        self.client = (
            client
            if client is not None
            else provider_client(ORIGIN, max_bytes=2 * 1024 * 1024, deadline=20)
        )

    async def close(self):
        await self.client.aclose()

    async def _get(self, path, params):
        try:
            response = await self.client.get(
                ORIGIN + path,
                params=params,
                headers={"Authorization": "Bearer " + self.token},
                follow_redirects=False,
            )
        except (httpx.HTTPError, OSError):
            raise XReadError("outcome_unknown") from None
        code = response.status_code
        if code != 200:
            kind = {
                400: "request_rejected",
                401: "authentication_failed",
                403: "permission_denied",
                404: "unavailable",
                429: "rate_limited",
            }.get(code, "http_error")
            retry = response.headers.get("retry-after", "")
            seconds = int(retry) if re.fullmatch(r"[0-9]{1,6}", retry) else None
            raise XReadError(kind, units=1, retry_after=seconds if code == 429 else None)
        try:
            if len(response.content) > 2 * 1024 * 1024:
                raise ValueError()
            body = response.json()
        except (ValueError, RecursionError):
            raise XReadError("malformed_response", units=1) from None
        if not isinstance(body, dict):
            raise XReadError("malformed_response", units=1)
        return body

    @staticmethod
    def _missing(body):
        errors = body.get("errors")
        if not isinstance(errors, list) or len(errors) != 1 or not isinstance(errors[0], dict):
            return False
        return errors[0].get("type") in {
            "https://api.x.com/2/problems/resource-not-found",
            "https://api.twitter.com/2/problems/resource-not-found",
        }

    async def user(self, value, *, by_id=False):
        path = "/2/users/" + remote_id(value) if by_id else "/2/users/by/username/" + handle(value)
        body = await self._get(path, {"user.fields": "id,username,protected"})
        if "data" not in body and self._missing(body):
            raise XReadError("unavailable", units=1)
        if body.get("errors"):
            raise XReadError("malformed_response", units=1)
        result = _user(body.get("data"))
        if by_id and result["remote_id"] != value:
            raise XReadError("identity_mismatch", units=1)
        if not by_id and result["handle"].lower() != handle(value):
            raise XReadError("identity_mismatch", units=1)
        return result, 1

    async def list(self, identity):
        body = await self._get(
            "/2/lists/" + remote_id(identity), {"list.fields": "id,name,private"}
        )
        if "data" not in body and self._missing(body):
            raise XReadError("unavailable", units=1)
        data = body.get("data")
        if (
            not isinstance(data, dict)
            or body.get("errors")
            or data.get("id") != identity
            or type(data.get("private")) is not bool
            or not isinstance(data.get("name"), str)
            or not data["name"].strip()
        ):
            raise XReadError("malformed_response", units=1)
        return dict(name=" ".join(data["name"].split())[:150], private=data["private"]), 1

    async def members(self, identity, size, token=None):
        if type(size) is not int or not 1 <= size <= 100:
            raise XReadError("invalid_page_size", units=0)
        params = {"max_results": size, "user.fields": "id,username,protected"}
        if token is not None:
            if not isinstance(token, str) or not _PAGE.fullmatch(token):
                raise XReadError("invalid_page_token", units=0)
            params["pagination_token"] = token
        body = await self._get("/2/lists/" + remote_id(identity) + "/members", params)
        meta = body.get("meta")
        data = body.get("data", [])
        count = max(1, len(data)) if isinstance(data, list) else 1
        if (
            not isinstance(data, list)
            or body.get("errors")
            or len(data) > size
            or not isinstance(meta, dict)
            or type(meta.get("result_count")) is not int
            or meta["result_count"] != len(data)
        ):
            raise XReadError("partial_response", units=count)
        next_token = meta.get("next_token")
        if next_token is not None and (
            not isinstance(next_token, str) or not _PAGE.fullmatch(next_token)
        ):
            raise XReadError("partial_response", units=count)
        try:
            members = [_user(row) for row in data]
        except XReadError:
            raise XReadError("partial_response", units=count) from None
        return (members, next_token), count

    async def timeline(
        self, kind, identity, size, *, cursor=None, token=None, start=None, end=None
    ):
        if kind not in {"account", "list"} or type(size) is not int:
            raise XReadError("invalid_timeline", units=0)
        params = {
            "max_results": size,
            "post.fields": "author_id,created_at,text,referenced_posts,possibly_sensitive,withheld",
        }
        identity = remote_id(identity)
        if kind == "account":
            if not 5 <= size <= 100 or not end or (cursor is None) == (start is None):
                raise XReadError("invalid_timeline", units=0)
            params["end_time"] = end
            if cursor is not None:
                params["since_id"] = remote_id(cursor)
            else:
                params["start_time"] = start
            path = f"/2/users/{identity}/tweets"
        else:
            if not 1 <= size <= 100 or any(v is not None for v in (cursor, start, end)):
                raise XReadError("invalid_timeline", units=0)
            path = f"/2/lists/{identity}/tweets"
        if token is not None:
            if not isinstance(token, str) or not _PAGE.fullmatch(token):
                raise XReadError("invalid_page_token", units=0)
            params["pagination_token"] = token
        body = await self._get(path, params)
        data, meta = body.get("data", []), body.get("meta")
        count = max(1, len(data)) if isinstance(data, list) else 1
        if (
            not isinstance(data, list)
            or body.get("errors")
            or len(data) > size
            or not isinstance(meta, dict)
            or type(meta.get("result_count")) is not int
            or meta["result_count"] != len(data)
        ):
            raise XReadError("partial_response", units=count)
        next_token = meta.get("next_token")
        if next_token is not None and (
            not isinstance(next_token, str) or not _PAGE.fullmatch(next_token)
        ):
            raise XReadError("partial_response", units=count)
        try:
            rows = [_post(item) for item in data]
        except (ValueError, OverflowError):
            raise XReadError("partial_response", units=count) from None
        return (rows, next_token), count
