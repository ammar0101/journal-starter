"""Task 4: Implement analyze_journal_entry using the OpenAI Responses API.

This project mandates the OpenAI Python SDK and a provider that supports the
Responses API, such as:
  - Microsoft Foundry Models
  - OpenAI proper

Set OPENAI_API_KEY, OPENAI_BASE_URL, and OPENAI_MODEL in your .env file.
Settings are loaded by ``api.config.Settings``.
"""

import json

from openai import AsyncOpenAI

from api.config import get_settings


def _default_client() -> AsyncOpenAI:
    """Construct the real OpenAI client from application settings.

    Called lazily from ``analyze_journal_entry`` so tests can inject a
    ``MockAsyncOpenAI`` without ever triggering this code path.
    """
    settings = get_settings()
    return AsyncOpenAI(
        api_key=settings.openai_api_key,
        base_url=settings.openai_base_url,
    )


async def analyze_journal_entry(
    entry_id: str,
    entry_text: str,
    client: AsyncOpenAI | None = None,
) -> dict:
    """Analyze a journal entry using the OpenAI Responses API.

    Args:
        entry_id: ID of the entry being analyzed (pass through to the result).
        entry_text: Combined work + struggle + intention text.
        client: OpenAI client. If None, a default one is constructed from
            application settings. Tests pass in a MockAsyncOpenAI here; production code
            in the router calls this with no ``client`` argument.

    Returns:
        A dict matching AnalysisResponse:
            {
                "entry_id":  str,
                "sentiment": str,   # "positive" | "negative" | "neutral"
                "summary":   str,
                "topics":    list[str],
            }

    TODO (Task 4):
      1. If ``client is None``, call ``_default_client()`` to construct one.
      2. Build an input that includes ``entry_text`` somewhere
         (the unit tests check that the entry text reaches the LLM).
      3. Call ``client.responses.create(...)`` with a model name
         (use ``get_settings().openai_model``).
      4. Parse ``response.output_text`` with ``json.loads()``.
      5. Return a dict with ``entry_id``, ``sentiment``, ``summary``, ``topics``.
    """

    """Analyze a journal entry using the OpenAI Responses API."""

    # 1. If client is None, call _default_client() to construct one
    if client is None:
        client = _default_client()

    settings = get_settings()

    # 2. Build an input that includes entry_text somewhere
    prompt = (
        "Analyze the following journal entry. Return a valid JSON object strictly matching this format: "
        '{"sentiment": "positive|negative|neutral", "summary": "...", "topics": ["..."]}. '
        f"\n\nJournal Entry:\n{entry_text}"
    )

    # 3. Call client.responses.create(...) with a model name
    response = await client.responses.create(model=settings.openai_model, input=prompt)

    # 4. Parse response.output_text with json.loads()
    parsed_data = json.loads(response.output_text)

    # 5. Return a dict with entry_id, sentiment, summary, topics
    return {
        "entry_id": entry_id,
        "sentiment": parsed_data.get("sentiment", "neutral"),
        "summary": parsed_data.get("summary", ""),
        "topics": parsed_data.get("topics", []),
    }
