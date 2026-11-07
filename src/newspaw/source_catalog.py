"""Small source suggestions, never automatic subscriptions or availability claims."""

from copy import deepcopy

_AI_SOURCES = (
    dict(
        id="openai_news",
        name="OpenAI News",
        kind="rss",
        url="https://openai.com/news/rss.xml",
        evidence="publisher_announcement",
        availability="not_verified",
        validation="preview_required",
    ),
    dict(
        id="hf_blog",
        name="Hugging Face Blog",
        kind="rss",
        url="https://huggingface.co/blog/feed.xml",
        evidence="publisher_announcement",
        availability="not_verified",
        validation="preview_required",
    ),
    dict(
        id="hf_hub",
        name="Hugging Face Hub",
        kind="github",
        url="https://github.com/huggingface/huggingface_hub",
        evidence="repository_events",
        availability="not_verified",
        validation="preview_required",
    ),
)


def ai_sources():
    """Metadata for the source picker; does not save config or enable collection."""
    return deepcopy(list(_AI_SOURCES))
