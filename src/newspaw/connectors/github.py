"""GitHub metadata and immutable relevant-file evidence; no cloning or execution."""

import base64
import binascii
from datetime import timedelta
from urllib.parse import quote, urlencode

from . import APIError, date, identifier, object_, sha, text


def normalized(value):
    return "\n".join(line.rstrip(" \t") for line in value.replace("\r\n", "\n").split("\n"))


async def content(api, root, path, revision):
    response = await api.get(
        f"{root}/contents/{quote(path, safe='/')}?{urlencode({'ref': revision})}", missing=True
    )
    if response is None:
        return None
    data = object_(api.json(response))
    if (
        data.get("type") != "file"
        or data.get("encoding") != "base64"
        or not isinstance(data.get("content"), str)
    ):
        raise APIError("unsupported_file")
    try:
        raw = base64.b64decode("".join(data["content"].split()), validate=True)
        if len(raw) > 256 * 1024:
            raise APIError("file_too_large")
        return raw.decode("utf-8")
    except (ValueError, UnicodeError, binascii.Error):
        raise APIError("invalid_file") from None


async def fetch(api, url, options, old, hours):
    repository = identifier(old[1] if old else options["repo"], path=True)
    root = "https://api.github.com/repos/" + repository
    data = object_(api.json(await api.get(root)))
    remote_id = data.get("id")
    if type(remote_id) is not int or remote_id <= 0:
        raise APIError("invalid_repository")
    remote_id = str(remote_id)
    canonical = identifier(data.get("full_name"), path=True)
    if len(canonical.split("/")) != 2:
        raise APIError("invalid_repository")
    if old and old[0] != remote_id:
        raise APIError("identity_changed")
    api.identity = (remote_id, canonical)
    root = "https://api.github.com/repos/" + canonical
    web = "https://github.com/" + canonical
    license_ = data.get("license")
    license_ = text(license_.get("spdx_id"), 150) if isinstance(license_, dict) else ""
    if license_ in {"", "NOASSERTION"}:
        license_ = "unknown"
    common = dict(
        repository=canonical,
        repository_id=remote_id,
        license=license_,
        license_basis="current_repository_metadata",
        api_available="not_verified",
        weights_available="not_verified",
        configured_url=url,
    )
    if options["releases"]:
        try:
            async for release in api.pages(root + "/releases?per_page=30"):
                if release.get("draft") is True:
                    continue
                identity = release.get("id")
                if type(identity) is not int or identity <= 0:
                    raise APIError("invalid_release")
                tag = text(release.get("tag_name"), 150)
                api.article(
                    title=text(release.get("name")) or f"{canonical} {tag}",
                    url=f"{web}/releases/tag/{quote(tag, safe='')}",
                    body=release.get("body"),
                    published=release.get("published_at"),
                    feed_url=url,
                    metadata={
                        **common,
                        "event_type": "release",
                        "release_id": str(identity),
                        "version": tag,
                        "created_at": text(release.get("created_at")),
                        "prerelease": release.get("prerelease") is True,
                        "publication_basis": "release_published_at",
                    },
                )
        except APIError as exc:
            api.gap(exc.kind)
            if exc.kind in {"rate_limited", "request_limit"}:
                raise
    ref = options.get("ref") or identifier(data.get("default_branch"), path=True)
    for path in options["paths"]:
        try:
            async for commit in api.pages(
                root + "/commits?" + urlencode(dict(path=path, sha=ref, per_page=30))
            ):
                revision = sha(commit.get("sha"))
                info = object_(commit.get("commit"))
                when = text(object_(info.get("committer")).get("date"))
                timestamp = date(when)
                if timestamp and timestamp < api.now - timedelta(hours=hours):
                    continue
                parents = commit.get("parents")
                if not isinstance(parents, list):
                    raise APIError("invalid_commit")
                parent = sha(object_(parents[0]).get("sha")) if parents else None
                current = await content(api, root, path, revision)
                previous = None
                comparison = "root_commit" if not parent else "compared"
                if parent:
                    try:
                        previous = await content(api, root, path, parent)
                    except APIError as exc:
                        if exc.kind in {"rate_limited", "request_limit"}:
                            raise
                        comparison = "parent_unavailable"
                        api.gap(exc.kind)
                if current is None and previous is None:
                    api.gap("file_missing")
                    continue
                if (
                    current is not None
                    and previous is not None
                    and normalized(current) == normalized(previous)
                ):
                    continue
                if parent and previous is None:
                    comparison = "parent_missing"
                deleted = current is None
                api.article(
                    title=f"{canonical}: {path} {'deleted' if deleted else 'updated'}",
                    url=f"{web}/commit/{revision}",
                    body=text(info.get("message"), 500)
                    + "\n"
                    + (current if current is not None else previous),
                    published=when,
                    feed_url=url,
                    metadata={
                        **common,
                        "event_type": "file_deleted" if deleted else "file_commit",
                        "commit": revision,
                        "parent": parent or "",
                        "path": path,
                        "comparison": comparison,
                        "author_date": text(object_(info.get("author", {})).get("date")),
                        "publication_basis": "commit_committer_date",
                    },
                )
        except APIError as exc:
            api.gap(exc.kind)
            if exc.kind in {"rate_limited", "request_limit"}:
                raise
