import logging
import os

from fastapi import FastAPI
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor

from api.routers.journal_router import router as journal_router
from api.telemetry import setup_telemetry

# TODO (Task 1): Configure logging here.
# Reference: https://docs.python.org/3/howto/logging.html
# Steps:
#   1. ``import logging`` at the top of this file.
#   2. Call ``logging.basicConfig(level=logging.INFO, format="...")``.
logging.basicConfig(
    level=logging.INFO, format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
)

setup_telemetry()

#   3. Log an INFO message on startup (e.g. "Journal API starting up").
logging.info("Journal API starting up")
app = FastAPI(
    title="Journal API",
    description="A simple journal API for tracking daily work, struggles, and intentions",
)


@app.get("/version")
def get_version() -> dict[str, str]:
    """Return the build commit SHA used to create the running container."""
    return {"commit": os.getenv("GIT_SHA", "unknown")}


FastAPIInstrumentor.instrument_app(app)
app.include_router(journal_router)
