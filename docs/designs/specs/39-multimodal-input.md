# D03 / #39 — Telegram screenshot and voice clues, local playback

Closes #39

Ordinary media is opt-in and owner-only. An attachment requires an explicit ordinary `/search` scope, or a reply to a confirmed ordinary briefing sent to this Bot and binding generation. The same scope and current capability are checked before Telegram metadata/download, before the paid provider intent and before using the result. An attachment without a verified capability receives a localized text alternative. Attachment results are used only as phrases for local news search.

Telegram files use the fixed Bot API origin, validated relative paths and bounded streaming. Photographs are decoded with pixel and dimension limits and normalized. Audio is decoded locally from a bounded stream, limited to three minutes of PCM, and rejected if malformed. ffmpeg has an execution timeout and temporary files are removed after errors and cancellation. Vision is a separately verified ordinary profile. Transcription uses an explicit official OpenAI audio profile and independent verification from a synthetic speech sample.

A single durable paid intent is keyed by Bot, generation and update ID. A policy change cannot create a second intent for the same update. Known costs and uncertain holds use the existing budget. Input file IDs are cleared at terminal processing and no transcript or media bytes are kept as permanent evidence.

`/listen` requires a reply to the exact authorized ordinary briefing. Local macOS speech uses a voice matching the frozen brief's English, Japanese or Simplified Chinese locale, sends the linked text and then MP3 through the existing send lane, and falls back to the linked text when unavailable. The resident service uses locally installed ffmpeg for optional audio processing. No automatic media download or voice delivery is enabled by default.

Validation uses bounded fake Telegram and model transports, policy changes after uncertain outcomes, child cancellation and temp cleanup, exact anchors, ordinary/adult separation, and actual local synthetic voices in all three languages. No live Telegram or model requests are required.

- [Telegram Bot API](https://core.telegram.org/bots/api#getfile)
- [OpenAI Create transcription](https://developers.openai.com/api/reference/resources/audio/subresources/transcriptions/methods/create)
