"""Bounded, fixed-origin X directory reads."""

from __future__ import annotations

import re
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
        raise XReadError("malformed_response")
    return dict(remote_id=value["id"], handle=value["username"], protected=value["protected"])


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
            }.get(code)
            if kind is None:
                raise XReadError("outcome_unknown")
            retry = response.headers.get("retry-after", "")
            seconds = int(retry) if re.fullmatch(r"[0-9]{1,6}", retry) else None
            raise XReadError(kind, units=1, retry_after=seconds if code == 429 else None)
        try:
            if len(response.content) > 2 * 1024 * 1024:
                raise ValueError()
            body = response.json()
        except (ValueError, RecursionError):
            raise XReadError("malformed_response") from None
        if not isinstance(body, dict):
            raise XReadError("malformed_response")
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
        count = max(1, len(data)) if isinstance(data, list) else None
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
