import json
from unittest.mock import Mock, patch

import pytest

from api.config import get_settings


@pytest.mark.no_db
def test_get_settings_loads_runtime_secret_from_secrets_manager(monkeypatch):
    secret_values = {
        "DATABASE_URL": "postgresql://journal_api:secret@db.example:5432/career_journal",
        "OPENAI_API_KEY": "test-key",
        "OPENAI_BASE_URL": "https://example.invalid/v1",
        "OPENAI_MODEL": "test-model",
    }
    client = Mock()
    client.get_secret_value.return_value = {"SecretString": json.dumps(secret_values)}
    resource_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:test"
    monkeypatch.setenv("APP_CONFIG_SECRET_ARN", resource_arn)
    monkeypatch.setenv("AWS_REGION", "us-east-1")
    get_settings.cache_clear()

    with patch("api.config.boto3.client", return_value=client):
        settings = get_settings()

    assert settings.database_url == secret_values["DATABASE_URL"]
    assert settings.openai_api_key == secret_values["OPENAI_API_KEY"]
    assert settings.openai_base_url == secret_values["OPENAI_BASE_URL"]
    assert settings.openai_model == secret_values["OPENAI_MODEL"]
    client.get_secret_value.assert_called_once_with(SecretId=resource_arn)
    get_settings.cache_clear()
