import json
import os
from functools import lru_cache

import boto3
from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Typed application settings.

    Values are loaded in this order (later sources override earlier ones):
      1. Defaults defined on the fields below.
      2. A ``.env`` file in the current working directory.
      3. Process environment variables.

    Environment variables are matched case-insensitively, so ``DATABASE_URL``
    in ``.env`` populates ``database_url`` on this model.
    """

    database_url: str = Field(
        description="PostgreSQL connection URL (e.g. postgresql://user:pass@host:5432/db).",
    )
    openai_api_key: str = Field(
        description=(
            "API key for a provider that supports the OpenAI Responses API. Task 4 uses it to "
            "construct an AsyncOpenAI client; during Tasks 1-3 any non-empty "
            "placeholder works."
        ),
    )
    openai_base_url: str = Field(
        description="Responses API-compatible v1 endpoint for the selected provider.",
    )
    openai_model: str = Field(
        description="Provider model ID or deployment name passed to responses.create().",
    )

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )


@lru_cache
def get_settings() -> Settings:
    """FastAPI dependency that returns a cached ``Settings`` instance.

    Tests can override this with::

        app.dependency_overrides[get_settings] = lambda: Settings(
            database_url="...",
            openai_api_key="...",
            openai_base_url="https://example.invalid/v1",
            openai_model="...",
        )
    """
    secret_arn = os.getenv("APP_CONFIG_SECRET_ARN")
    if secret_arn:
        region = os.getenv("AWS_REGION", "us-east-1")
        response = boto3.client("secretsmanager", region_name=region).get_secret_value(
            SecretId=secret_arn
        )
        secret_string = response.get("SecretString")
        if secret_string is None:
            raise ValueError("Application configuration secret has no SecretString")
        values = json.loads(secret_string)
        return Settings(
            database_url=values["DATABASE_URL"],
            openai_api_key=values["OPENAI_API_KEY"],
            openai_base_url=values["OPENAI_BASE_URL"],
            openai_model=values["OPENAI_MODEL"],
            _env_file=None,  # type: ignore[call-arg]
        )

    secrets_dir = os.getenv("APP_SECRETS_DIR")
    if secrets_dir:
        return Settings(_secrets_dir=secrets_dir, _env_file=None)  # type: ignore[call-arg]
    return Settings()  # type: ignore[call-arg]
