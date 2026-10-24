import asyncio
import json
import logging
import os
from urllib.parse import urlparse

import asyncpg
import boto3

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger(__name__)


def get_secret(secret_id: str) -> dict[str, str]:
    response = boto3.client(
        "secretsmanager", region_name=os.environ["AWS_REGION"]
    ).get_secret_value(SecretId=secret_id)
    secret_string = response.get("SecretString")
    if secret_string is None:
        raise ValueError(f"Secret {secret_id} has no SecretString")
    return json.loads(secret_string)


def quote_sql_literal(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def quote_sql_identifier(value: str) -> str:
    return '"' + value.replace('"', '""') + '"'


async def main() -> None:
    master = get_secret(os.environ["RDS_MASTER_SECRET_ARN"])
    runtime = get_secret(os.environ["APP_CONFIG_SECRET_ARN"])
    db_password = runtime["APP_DB_PASSWORD"]
    database_url = urlparse(runtime["DATABASE_URL"])
    if database_url.hostname is None:
        raise ValueError("Application database URL has no hostname")
    database_host = database_url.hostname
    database_port = database_url.port or 5432
    database_name = database_url.path.lstrip("/")
    if not database_name:
        raise ValueError("Application database URL has no database name")

    connection = await asyncpg.connect(
        host=database_host,
        port=database_port,
        user=master["username"],
        password=master["password"],
        database="postgres",
        ssl="require",
    )
    try:
        role_exists = await connection.fetchval(
            "SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'journal_api')"
        )
        password_sql = quote_sql_literal(db_password)
        if role_exists:
            await connection.execute(f"ALTER ROLE journal_api WITH LOGIN PASSWORD {password_sql}")
        else:
            await connection.execute(f"CREATE ROLE journal_api WITH LOGIN PASSWORD {password_sql}")
        await connection.execute(
            f"GRANT CONNECT ON DATABASE {quote_sql_identifier(database_name)} TO journal_api"
        )
    finally:
        await connection.close()

    connection = await asyncpg.connect(
        host=database_host,
        port=database_port,
        user=master["username"],
        password=master["password"],
        database=database_name,
        ssl="require",
    )
    try:
        await connection.execute(
            """
            CREATE TABLE IF NOT EXISTS entries (
                id VARCHAR PRIMARY KEY,
                data JSONB NOT NULL,
                created_at TIMESTAMP WITH TIME ZONE NOT NULL,
                updated_at TIMESTAMP WITH TIME ZONE NOT NULL
            )
            """
        )
        await connection.execute(
            "CREATE INDEX IF NOT EXISTS idx_entries_created_at ON entries(created_at)"
        )
        await connection.execute(
            "CREATE INDEX IF NOT EXISTS idx_entries_data_gin ON entries USING GIN (data)"
        )
        await connection.execute("GRANT USAGE, CREATE ON SCHEMA public TO journal_api")
        await connection.execute(
            "GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO journal_api"
        )
        await connection.execute(
            """
            ALTER DEFAULT PRIVILEGES IN SCHEMA public
            GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO journal_api
            """
        )
    finally:
        await connection.close()

    logger.info("Database schema and journal_api role are ready")


if __name__ == "__main__":
    asyncio.run(main())
