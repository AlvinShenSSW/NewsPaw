"""Model-card metadata; neither weights nor inference are requested."""

from urllib.parse import urlencode

from . import APIError, identifier, object_, sha, text


async def model(api, url, repo):
    root = "https://huggingface.co"
    data = object_(api.json(await api.get(f"{root}/api/models/{repo}")))
    canonical = identifier(data.get("id"), path=True)
    if canonical != repo:
        raise APIError("model_identity_changed")
    revision = sha(data.get("sha"))
    card = data.get("cardData")
    license_ = text(card.get("license"), 150) if isinstance(card, dict) else ""
    siblings = data.get("siblings", [])
    if not isinstance(siblings, list):
        raise APIError("invalid_response")
    weights = any(
        text(object_(v).get("rfilename")).lower().endswith((".safetensors", ".bin", ".gguf"))
        for v in siblings
    )
    gated = data.get("gated")
    gated = gated if gated in ("auto", "manual") or gated is False else "unknown"
    body = ""
    try:
        response = await api.get(f"{root}/{repo}/resolve/{revision}/README.md", missing=True)
        if response is None:
            api.gap("model_card_missing")
        elif len(response.content) > 256 * 1024:
            api.gap("file_too_large")
        else:
            body = response.content.decode("utf-8")
    except UnicodeError:
        api.gap("invalid_file")
    except APIError as exc:
        if exc.kind in {"rate_limited", "request_limit"}:
            raise
        api.gap(exc.kind)
    created = text(data.get("createdAt"))
    modified = text(data.get("lastModified"))
    event = "model_created" if modified == created else "model_revision"
    api.article(
        title=f"{repo} {event}",
        url=f"{root}/{repo}/commit/{revision}",
        body=body or f"{repo} repository metadata",
        published=created if event == "model_created" else modified,
        updated=modified,
        feed_url=url,
        metadata=dict(
            repository=repo,
            model_version=revision,
            license=license_ or "unknown",
            license_basis="current_model_card_metadata",
            event_type=event,
            original_created_at=created,
            publication_basis="model_created_at"
            if event == "model_created"
            else "model_last_commit",
            gated=gated,
            weights_available="listed_not_download_verified" if weights else "not_verified",
            api_available="not_verified",
        ),
    )


async def fetch(api, url, options, old, hours):
    if "author" not in options:
        await model(api, url, options["repo"])
        return
    count = 0
    async for item in api.pages(
        "https://huggingface.co/api/models?"
        + urlencode(
            dict(
                author=options["author"],
                sort="lastModified",
                direction=-1,
                limit=10,
                full="true",
                cardData="true",
            )
        )
    ):
        if count >= 10:
            api.gap("model_limit")
            break
        repo = identifier(item.get("id"), path=True)
        if len(repo.split("/")) != 2 or repo.split("/")[0] != options["author"]:
            raise APIError("model_identity_changed")
        count += 1
        try:
            await model(api, url, repo)
        except APIError as exc:
            api.gap(exc.kind)
            if exc.kind in {"rate_limited", "request_limit"}:
                raise
