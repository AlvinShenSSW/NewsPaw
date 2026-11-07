"""Controlled publication vocabulary for the AV industry subscription."""

import re

AV_CONTRACT = "industry-v1"
AV_PUBLISHER = "AV研究所"
_TOPICS = {
    "release": re.compile("発売|配信開始|リリース"),
    "campaign": re.compile("キャンペーン|割引|セール"),
    "event": re.compile("イベント|開催|登壇"),
    "publication": re.compile("写真集|雑誌|刊行"),
}
_BRANDS = ("FANZA", "MGS", "SOD", "FALENO", "DAHLIA")
_COPY = {
    "zh-Hans": {
        "release": ("发行动态", "报道了一项发行公告"),
        "campaign": ("宣传活动", "报道了一项宣传活动"),
        "event": ("行业活动", "报道了一项行业活动"),
        "publication": ("出版动态", "报道了一项出版消息"),
    },
    "en": {
        "release": ("Release announcement", "reported a release announcement"),
        "campaign": ("Promotional campaign", "reported a promotional campaign"),
        "event": ("Industry event", "reported an industry event"),
        "publication": ("Publishing update", "reported a publication update"),
    },
    "ja": {
        "release": ("発売のお知らせ", "発売のお知らせを報じました"),
        "campaign": ("キャンペーンのお知らせ", "キャンペーンを報じました"),
        "event": ("業界イベントのお知らせ", "業界イベントを報じました"),
        "publication": ("出版のお知らせ", "出版の動きを報じました"),
    },
}


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


def industry_copy(locale, fact):
    if not isinstance(fact, dict):
        return None
    topic, brand = fact.get("topic"), fact.get("brand")
    labels = _COPY[locale].get(topic)
    if labels is None or (brand is not None and brand not in _BRANDS):
        return None
    title, body = labels
    if locale == "en":
        return (f"{title} · {brand}" if brand else title, f"{AV_PUBLISHER} {body}.")
    return (
        f"{title} · {brand}" if brand else title,
        f"{AV_PUBLISHER}が{body}。" if locale == "ja" else f"{AV_PUBLISHER}{body}。",
    )
