# ==========================================
# Builder Stage
# ==========================================
FROM python:3.14-slim AS builder

# Copy the standalone uv binary directly from Astral's official image
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

# Enable bytecode compilation to speed up the FastAPI application startup
ENV UV_COMPILE_BYTECODE=1 

WORKDIR /app

# Copy dependency files first to leverage Docker layer caching
COPY pyproject.toml uv.lock ./

# Install dependencies into a virtual environment at /app/.venv
# --frozen ensures exact versions from the lock file
# --no-dev excludes testing tools, and --no-install-project skips the app code for now
RUN uv sync --no-dev --no-install-project

# Copy the rest of the application code from your local machine
COPY . /app

# Run a final sync to install the project itself
RUN uv sync --no-dev

# ==========================================
# Runtime Stage
# ==========================================
FROM python:3.14-slim

# Accept the Git commit SHA at build time and expose it to the app at runtime.
ARG GIT_SHA=unknown
ENV GIT_SHA=${GIT_SHA}

WORKDIR /app

# Copy the fully built virtual environment and application code from the builder
COPY --from=builder /app /app

# Expose the standard web port
EXPOSE 8000

# Start the FastAPI application using the virtual environment executable
CMD ["/app/.venv/bin/fastapi", "run", "api/main.py", "--port", "8000", "--host", "0.0.0.0"]