"""Collection cues and the delivery marker for the AV industry subscription."""

import re

# Marks a result written under the AV rules. "industry-v1" results held fixed template copy.
AV_CONTRACT = "summary-v2"
AV_CONTRACTS = frozenset({"industry-v1", AV_CONTRACT})
AV_PUBLISHER = "AV研究所"
_TOPICS = {
    "release": re.compile("発売|配信開始|リリース"),
    "campaign": re.compile("キャンペーン|割引|セール"),
    "event": re.compile("イベント|開催|登壇"),
    "publication": re.compile("写真集|雑誌|刊行"),
}
_BRANDS = ("FANZA", "MGS", "SOD", "FALENO", "DAHLIA")


def industry_fact(title, excerpt):
    text = title + "\n" + excerpt
    for topic, cue in _TOPICS.items():
        if cue.search(text):
            brand = next(
                (
                    brand
                    for brand in _BRANDS
                    if re.search(rf"(?<![A-Za-z0-9]){brand}(?![A-Za-z0-9])", text, re.IGNORECASE)
                ),
                None,
            )
            return {"topic": topic, "brand": brand}
    return None
