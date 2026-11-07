from __future__ import annotations

import json
from types import SimpleNamespace
from unittest.mock import AsyncMock, Mock

import pytest

import newspaw.ai as ai_module
from newspaw.ai import AIError, AIService
from newspaw.grok import AVModelService, GrokService
from newspaw.news import Article


@pytest.fixture
def client_factory(monkeypatch):
    client = SimpleNamespace(
        responses=SimpleNamespace(create=AsyncMock()),
        close=AsyncMock(),
    )
    factory = Mock(return_value=client)
    monkeypatch.setattr(ai_module, "AsyncOpenAI", factory)
    return client, factory


@pytest.mark.parametrize(
    "provider,endpoint,model",
    [
        ("grok", "https://api.x.ai/v1", "grok-4.7"),
        ("deepseek", "https://api.deepseek.com", "deepseek-flash"),
    ],
)
def test_av_provider_keeps_separate_credentials_and_endpoint(
    client_factory, monkeypatch, provider, endpoint, model
):
    _, factory = client_factory
    monkeypatch.setenv("OPENAI_API_KEY", "ordinary-news-key")
    service = AVModelService(provider, api_key="av-provider-key")
    assert service.enabled
    assert service.model == model
    assert factory.call_args.kwargs["api_key"] == "av-provider-key"
    assert factory.call_args.kwargs["base_url"] == endpoint


@pytest.mark.asyncio
async def test_absent_av_key_does_not_use_openai_environment(client_factory, monkeypatch):
    _, factory = client_factory
    monkeypatch.setenv("OPENAI_API_KEY", "ordinary-news-key")
    service = GrokService()
    assert not service.enabled
    with pytest.raises(AIError):
        await service.plan_collection(["av"])
    with pytest.raises(AIError):
        await service.summarize([Article("Release", "https://example.test/item", "Studio")])
    factory.assert_not_called()


@pytest.mark.parametrize(
    "provider,url",
    [
        ("grok", "https://api.openai.com/v1"),
        ("deepseek", "https://api.x.ai/v1"),
        ("grok", "https://api.x.ai.evil.test/v1"),
        ("grok", "http://api.x.ai/v1"),
        ("grok", "https://password@api.x.ai/v1"),
    ],
)
def test_av_rejects_cross_provider_and_unsafe_endpoints(client_factory, provider, url):
    _, factory = client_factory
    with pytest.raises(AIError):
        AVModelService(provider, "av-provider-key", base_url=url)
    factory.assert_not_called()


@pytest.mark.asyncio
@pytest.mark.parametrize("provider", ["grok", "deepseek"])
async def test_av_summary_omits_unedited_source_title_and_images(client_factory, provider):
    client, _ = client_factory
    client.responses.create.return_value = SimpleNamespace(
        output_text=json.dumps(
            {
                "items": [{"index": 1, "summary": "制作公司公布了新的发行日期。"}],
                "conflicts": [],
            }
        ),
    )
    service = AVModelService(provider, "av-provider-key")
    article = Article(
        "RAW_MARKETING_TITLE_MUST_NOT_BE_FORWARDED",
        "https://example.test/item",
        "Studio",
        summary="The studio announced a release date.",
        image_url="https://example.test/photo.jpg",
    )
    result = await service.summarize([article])
    assert result == "[1] 制作公司公布了新的发行日期。"
    request = client.responses.create.call_args.kwargs
    assert "photo.jpg" not in request["input"]
    assert "tools" not in request
    assert request["store"] is False
    assert ("strict" in request["text"]["format"]) == (provider == "grok")


@pytest.mark.asyncio
@pytest.mark.parametrize("provider", ["grok", "deepseek"])
async def test_av_invalid_source_reference_stops_without_fallback(client_factory, provider):
    client, factory = client_factory
    client.responses.create.return_value = SimpleNamespace(
        output_text=json.dumps(
            {"items": [{"index": 99, "summary": "Unattributable."}], "conflicts": []}
        ),
    )
    service = AVModelService(provider, "av-provider-key")
    with pytest.raises(AIError, match="不发送原始摘录"):
        await service.summarize([Article("Release", "https://example.test/item", "Studio")])
    factory.assert_called_once()
    client.responses.create.assert_awaited_once()


def collection_response(topics, *, name="collect_news", extra=None):
    arguments = {"topics": topics, **(extra or {})}
    return SimpleNamespace(
        status="completed",
        output=[SimpleNamespace(type="function_call", name=name, arguments=json.dumps(arguments))],
    )


@pytest.mark.asyncio
@pytest.mark.parametrize("provider", ["openai", "grok", "deepseek"])
async def test_model_collection_preserves_user_topics_and_uses_only_bounded_tool(
    client_factory, provider
):
    client, _ = client_factory
    service = (
        AIService("normal-key") if provider == "openai" else AVModelService(provider, "av-key")
    )
    topics = ["world", "japan"] if provider == "openai" else ["av"]
    client.responses.create.return_value = collection_response(list(reversed(topics)))
    assert await service.plan_collection(topics) == topics
    request = client.responses.create.call_args.kwargs
    assert [tool["name"] for tool in request["tools"]] == ["collect_news"]
    assert request["tools"][0]["parameters"]["properties"]["topics"]["items"]["enum"] == topics
    assert request["tool_choice"] == {"type": "function", "name": "collect_news"}


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "topics,name,extra",
    [
        (["world"], "collect_news", None),
        (["world", "world"], "collect_news", None),
        (["world", "unrequested"], "collect_news", None),
        (["world", "japan"], "execute_shell", None),
        (["world", "japan"], "collect_news", {"url": "http://127.0.0.1"}),
    ],
)
async def test_collection_rejects_changed_scope_or_arbitrary_arguments(
    client_factory, topics, name, extra
):
    client, _ = client_factory
    client.responses.create.return_value = collection_response(topics, name=name, extra=extra)
    with pytest.raises(AIError):
        await AIService("normal-key").plan_collection(["world", "japan"])


@pytest.mark.asyncio
async def test_collection_rejects_multiple_calls(client_factory):
    client, _ = client_factory
    response = collection_response(["av"])
    response.output.append(response.output[0])
    client.responses.create.return_value = response
    with pytest.raises(AIError):
        await GrokService("av-key").plan_collection(["av"])


@pytest.mark.asyncio
async def test_provider_failure_redacts_details_and_never_constructs_fallback(client_factory):
    client, factory = client_factory
    client.responses.create.side_effect = RuntimeError("provider secret response")
    service = AVModelService("deepseek", "av-key")
    with pytest.raises(AIError) as error:
        await service.plan_collection(["av"])
    assert "secret" not in str(error.value)
    factory.assert_called_once()
    await service.close()
    client.close.assert_awaited_once()
