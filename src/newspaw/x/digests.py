"""Scoped X news collection on the existing timeline and evidence stores."""

from __future__ import annotations

import hashlib
from datetime import datetime, timedelta
from uuid import uuid4

from ..app_config import X_DEFAULT_POST_TYPES, in_x_aggregate, x_post_types
from ..newsparse import Article
from .timelines import TimelineError, same_timeline_binding, timeline_access_current

_REUSE = timedelta(hours=1)
_WINDOW = timedelta(hours=24)
_ACTIVE = {"pending", "budget_blocked", "rate_limited", "http_error"}


def initialize(db):
    db.execute(
        """CREATE TABLE IF NOT EXISTS x_digest_links (
           job_id TEXT NOT NULL, group_id INTEGER NOT NULL,
           scan_id TEXT NOT NULL REFERENCES x_timeline_scans(id),
           PRIMARY KEY(job_id,group_id))"""
    )


def x_scope(config, subscription_id, account_id, special):
    sub = next((row for row in config["subscriptions"] if row["id"] == subscription_id), None)
    account = next((row for row in config["accounts"] if row["id"] == account_id), None)
    if (
        sub is None
        or not sub["enabled"]
        or sub["category_id"] not in {"x", "x_adult"}
        or account is None
        or account["subscription_id"] != subscription_id
        or not account["remote_id"]
    ):
        return None
    partition = "adult" if sub["category_id"] == "x_adult" else "normal"
    if (
        account["partition"] != partition
        or (special is None and not in_x_aggregate(account, sub))
        or (special is not None and (special != account_id or account["priority"] != "special"))
    ):
        return None
    source_id = "x:" + account_id
    url = "https://x.com/i/user/" + account["remote_id"]
    ref = config["x_api"]["credential_ref"]
    post_types = x_post_types(account["post_types"]) if "post_types" in account else None
    type_scope = (
        {"post_types": post_types}
        if post_types is not None and tuple(post_types) != X_DEFAULT_POST_TYPES
        else {}
    )
    return dict(
        url=url,
        partition=partition,
        subscriptions=[subscription_id],
        source_id=None,
        kinds=["x_account"],
        evidence_scope="x_post_excerpt",
        x_digest=dict(
            account=account_id,
            handle=account["handle"],
            remote=account["remote_id"],
            special=special,
            credential_tag=hashlib.sha256(ref.encode()).hexdigest() if ref else None,
            **type_scope,
        ),
        selected=[
            dict(
                source=dict(
                    id=source_id, url=url, partition=partition, kind="x_account", enabled=True
                ),
                association=dict(
                    source_id=source_id,
                    subscription_id=subscription_id,
                    category_id=sub["category_id"],
                ),
            )
        ],
    )


def x_scopes(config, route):
    accounts = (
        [route.effective["account"]]
        if route.account_id is not None
        else route.effective["accounts"]
    )
    return [
        scope
        for account in accounts
        if (scope := x_scope(config, route.subscription_id, account["id"], route.account_id))
        is not None
    ]


def _excerpt(body):
    return " ".join(body.split())[:1500]


def x_post_available(db, partition, proof, ref):
    row = db.execute(
        """SELECT p.body,i.direct FROM x_posts p JOIN x_identities i ON i.account_id=p.account_id
           WHERE p.partition=? AND p.id=? AND p.account_id=? AND p.author_id=?
             AND p.tombstone=0 AND p.body IS NOT NULL
             AND i.state='ready' AND i.remote_id=p.author_id AND i.credential_ref=?""",
        (partition, proof["id"], proof["account"], proof["author_id"], ref),
    ).fetchone()
    if row is None or hashlib.sha256(_excerpt(row[0]).encode()).hexdigest() != proof["body_sha256"]:
        return False
    return timeline_access_current(db, "account", proof["account"]) and bool(
        row[1]
        or db.execute(
            """SELECT 1 FROM x_lists l,json_each(l.members) m
               WHERE l.authorized=1 AND l.credential_ref=?
                 AND json_extract(m.value,'$.account_id')=? AND json_extract(m.value,'$.remote_id')=?
               LIMIT 1""",
            (ref, proof["account"], proof["author_id"]),
        ).fetchone()
    )


def _article(scope, post):
    item = scope["x_digest"]
    text = _excerpt(post["text"])
    observed = post["observed_at"]
    published = datetime.fromisoformat(post["published_at"])
    handle = "@" + item["handle"]
    return Article(
        title=(handle + " · " + text)[:200],
        url=post["url"],
        source=handle,
        published_at=published,
        summary=text,
        fetched_at=datetime.fromisoformat(observed) if observed else None,
        feed_url=scope["url"],
        published_raw=post["published_at"],
        evidence_scope=scope["evidence_scope"],
        metadata=dict(
            x_post=dict(
                id=post["id"],
                account=item["account"],
                author=handle,
                author_id=post["author_id"],
                body_sha256=hashlib.sha256(text.encode()).hexdigest(),
                type=(
                    "+".join(sorted({ref["type"] for ref in post["references"]})).replace(
                        "quoted", "quote"
                    )
                    or "original"
                ),
                referenced_ids=[entry["id"] for entry in post["references"]],
            )
        ),
    )


class XDigests:
    def __init__(self, timelines):
        self.timelines = timelines
        self.store, self.db = timelines.store, timelines.db

    def _compatible(self, scan, binding, types):
        return scan["args"]["types"] == types and same_timeline_binding(scan["binding"], binding)

    def _link(self, scope):
        job = scope["collection_id"]
        group = scope["collection_group"]
        account = scope["x_digest"]["account"]
        types = scope["x_digest"].get("post_types", list(X_DEFAULT_POST_TYPES))
        binding = self.timelines._scope("account", account)
        prior = self.db.execute(
            "SELECT scan_id FROM x_digest_links WHERE job_id=? AND group_id=?", (job, group)
        ).fetchone()
        if prior:
            scan = self.timelines._scan(prior[0])
            if not self._compatible(scan, binding, types):
                raise TimelineError("configuration_changed")
            return scan
        last = self.timelines._last_scan("account", account)
        scan = self.timelines._scan(last[0]) if last else None
        now = self.timelines.clock()
        reuse = bool(
            scan
            and self._compatible(scan, binding, types)
            and (
                (
                    scan["state"] == "complete"
                    and now - _REUSE <= datetime.fromisoformat(scan["updated_at"]) <= now
                )
                or (
                    scan["state"] == "pending"
                    and scan["args"].get("max_pages") == 2
                    and scan["binding"] == binding
                )
            )
        )
        if not reuse:
            if scan and scan["state"] in _ACTIVE:
                if scan["args"].get("max_pages") != 2:
                    raise TimelineError("scan_in_progress")
                self.timelines.stop(scan["id"])
            cursor = self.timelines._cursor(account, binding)
            fresh = bool(
                cursor and self.timelines.cursor_requires_fresh(account, binding, types, cursor)
            )
            identity = "digest." + uuid4().hex
            self.timelines.begin(
                identity,
                "account",
                account,
                binding["revision"],
                fresh=fresh,
                max_pages=2,
                include_original="original" in types,
                include_quotes="quoted" in types,
                include_replies="replied_to" in types,
                include_reposts="retweeted" in types,
            )
            scan = self.timelines._scan(identity)
        with self.store._write():
            self.db.execute("INSERT INTO x_digest_links VALUES (?,?,?)", (job, group, scan["id"]))
        return scan

    def _result(self, scope, scan, anchor):
        handle = "@" + scope["x_digest"]["handle"]
        partition = scope["partition"]
        progress = scan["progress"]
        end = datetime.fromisoformat(progress["end"])
        start = (
            datetime.fromisoformat(progress["covered_start"])
            if progress.get("covered_start")
            else None
        )
        complete = scan["state"] == "complete" and start is not None and start <= end - _WINDOW
        reasons = []
        if progress.get("history_gap"):
            reasons.append(progress["history_gap"])
        if progress.get("reason"):
            reasons.append(progress["reason"])
        if scan["state"] == "complete" and not complete:
            reasons.append("coverage_start_unverified")
        if end < anchor.replace(microsecond=0):
            reasons.append("reused_through_prior_time")
        if not complete and not reasons:
            reasons.append("coverage_incomplete")
        articles = []
        if scan["state"] in {"complete", "incomplete"} and progress["pages"] > 0:
            ref = self.store.load_config()[1]["x_api"]["credential_ref"]
            posts = self.timelines.posts(
                "account",
                scan["scope"],
                limit=200,
                frozen_scan=scan["id"],
                anchor=end,
            )
            articles = [
                article
                for post in posts
                if post["partition"] == partition
                and (article := _article(scope, post)).summary
                and x_post_available(self.db, partition, article.metadata["x_post"], ref)
            ]
        status = (
            "fresh"
            if articles
            else "empty"
            if complete
            else "outcome_unknown"
            if scan["state"] == "outcome_unknown"
            else "failed"
        )
        covered_from = start if scan["state"] == "complete" else None
        if scan["state"] == "incomplete" and progress["last"]:
            covered_from = datetime.fromisoformat(progress["last"][0])
        return dict(
            status=status,
            accepted_count=len(articles),
            coverage_complete=complete,
            coverage_gaps=reasons,
            x_coverage=dict(
                author=handle,
                from_time=covered_from.isoformat() if covered_from else None,
                through_time=end.isoformat() if progress["pages"] > 0 else None,
                state=scan["state"],
            ),
        ), articles

    async def fetch_scope(self, evidence, scope, anchor, *, before_intent):
        if not evidence.current(scope):
            raise TimelineError("configuration_changed")
        try:
            scan = self._link(scope)
            if scan["state"] == "pending":
                step = f"{scan['id']}.{scan['progress']['pages'] + 1}"
                await self.timelines.advance(scan["id"], step, before_intent=before_intent)
                scan = self.timelines._scan(scan["id"])
            if scan["state"] in _ACTIVE:
                return None
            outcome, articles = self._result(scope, scan, anchor)
        except TimelineError as exc:
            if str(exc) == "configuration_changed":
                raise
            reason = str(exc)
            outcome = dict(
                status="outcome_unknown" if reason == "prior_outcome_unknown" else "failed",
                accepted_count=0,
                coverage_complete=False,
                coverage_gaps=[reason],
                x_coverage=dict(
                    author="@" + scope["x_digest"]["handle"],
                    from_time=None,
                    through_time=None,
                    state="unavailable",
                ),
            )
            articles = []
        checked = self.timelines.clock()
        identity = evidence.begin(scope, checked)
        if identity is None:
            return None
        return evidence.finish(
            identity, scope, outcome, checked, articles=articles, rejected={}, cache=False
        )
