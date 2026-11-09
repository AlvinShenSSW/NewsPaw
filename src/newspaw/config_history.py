"""Recent configuration revisions, so the app can see what changed in the background (E10 R05).

A trigger records every write to ``app_configuration`` whichever module makes it (saves, key
and probe bookkeeping, Bot verification and pairing), keeping the last ``KEEP`` revisions.
"""

import json

from .credentials import CredentialError

KEEP = 50


def initialize(db):
    db.execute(
        """CREATE TABLE IF NOT EXISTS app_configuration_history (
            revision INTEGER PRIMARY KEY, document TEXT NOT NULL
        )"""
    )
    db.execute(
        f"""CREATE TRIGGER IF NOT EXISTS app_configuration_history_record
            AFTER UPDATE OF revision, document ON app_configuration
            BEGIN
                INSERT OR REPLACE INTO app_configuration_history VALUES (NEW.revision, NEW.document);
                DELETE FROM app_configuration_history WHERE revision <= NEW.revision - {KEEP};
            END"""
    )
    db.execute(
        """INSERT OR IGNORE INTO app_configuration_history
           SELECT revision, document FROM app_configuration WHERE id=1"""
    )


def _diff(before, after):
    changes = []
    for key in sorted(set(before) | set(after)):
        old, new = before.get(key), after.get(key)
        if old == new:
            continue
        keyed = all(
            isinstance(items, list) and all(isinstance(row, dict) and "id" in row for row in items)
            for items in (old or [], new or [])
        )
        if not keyed or old is None or new is None:
            changes.append({"field": key})
            continue
        earlier = {row["id"]: row for row in old}
        later = {row["id"]: row for row in new}
        for identity in sorted(set(earlier) | set(later)):
            if identity not in later:
                changes.append({"collection": key, "id": identity, "removed": True})
            elif identity not in earlier:
                changes.append({"collection": key, "id": identity, "added": True})
            elif earlier[identity] != later[identity]:
                fields = sorted(
                    name
                    for name in set(earlier[identity]) | set(later[identity])
                    if earlier[identity].get(name) != later[identity].get(name)
                )
                changes.append({"collection": key, "id": identity, "fields": fields})
    return changes


def changes_since(store, revision):
    """What changed between ``revision`` and now: top-level fields, and per collection item
    its changed fields (or added/removed). Older than the kept history: history_unavailable."""
    current, document = store.load_config()
    if type(revision) is not int or not 1 <= revision <= current:
        raise CredentialError("invalid_revision")
    row = store._db.execute(
        "SELECT document FROM app_configuration_history WHERE revision=?", (revision,)
    ).fetchone()
    if row is None:
        raise CredentialError("history_unavailable")
    return {"revision": current, "changes": _diff(json.loads(row[0]), document)}
