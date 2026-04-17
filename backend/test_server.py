"""
backend/test_server.py

Unit tests for the server's HTTP endpoints.

The default backend is USE_VLLM=false (transformers/CPU) because vLLM only
runs on x86_64 Linux with CUDA — it cannot be installed on Apple Silicon or
in a standard CI environment. These tests mock the transformers package so
that torch and transformers don't need to be installed at all.

Mocking strategy:
  1. Set USE_VLLM=false (matches the default)
  2. Inject a fake 'transformers' module into sys.modules before importing server
  3. Import server — it finds our fake instead of the real library
  4. Tests verify the HTTP routing logic with a fake model response
"""

import os
import sys
from unittest.mock import MagicMock
import pytest


# ── Step 1: Configure environment before importing server ─────────────────────
# server.py reads USE_VLLM at module load time (the top-level if/else).
# These must be set before `import server`.

os.environ["USE_VLLM"] = "false"
os.environ["MODEL_NAME"] = "test-model"
os.environ["START_METRICS_SERVER"] = "false"  # don't bind port 9090 in tests


# ── Step 2: Mock the 'transformers' package ───────────────────────────────────
# sys.modules is a dict Python checks before looking on disk for a package.
# By injecting a fake here, we prevent Python from ever loading the real
# library — so torch and transformers don't need to be installed for tests.

def _fake_pipe(prompt, **kwargs):
    """
    Mimics the real transformers pipeline return value.
    The real pipeline returns the prompt concatenated with generated text,
    e.g. input "Say hello" → [{"generated_text": "Say hello world"}].
    server.py strips the prompt prefix, leaving just " world".
    """
    return [{"generated_text": prompt + " [mock response]"}]

mock_transformers = MagicMock()
mock_transformers.pipeline.return_value = MagicMock(side_effect=_fake_pipe)
sys.modules["transformers"] = mock_transformers
sys.modules["accelerate"] = MagicMock()


# ── Step 3: Now it is safe to import server ───────────────────────────────────
from fastapi.testclient import TestClient  # noqa: E402
import server                              # noqa: E402


# ── Fixtures ──────────────────────────────────────────────────────────────────

@pytest.fixture
def client():
    """TestClient sends HTTP requests to the FastAPI app in memory."""
    return TestClient(server.app)


# ── Tests ─────────────────────────────────────────────────────────────────────

def test_health_returns_ok(client):
    """GET /health should return 200 with status=ok and backend=transformers."""
    response = client.get("/health")
    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "ok"
    assert body["backend"] == "transformers"


def test_models_lists_the_configured_model(client):
    """
    GET /v1/models should return the model name from MODEL_NAME env var.
    OpenWebUI calls this on startup to populate the model dropdown.
    """
    response = client.get("/v1/models")
    assert response.status_code == 200
    body = response.json()
    assert body["object"] == "list"
    assert body["data"][0]["id"] == "test-model"


def test_chat_returns_assistant_message(client):
    """POST /v1/chat/completions should return an OpenAI-format response."""
    response = client.post("/v1/chat/completions", json={
        "messages": [{"role": "user", "content": "Say hello"}],
        "max_tokens": 50,
    })
    assert response.status_code == 200
    body = response.json()
    assert "choices" in body
    assert body["choices"][0]["message"]["role"] == "assistant"
    assert len(body["choices"][0]["message"]["content"]) > 0


def test_chat_requires_messages(client):
    """
    A request with no 'messages' field should return HTTP 422.
    FastAPI validates this automatically from the Pydantic schema.
    """
    response = client.post("/v1/chat/completions", json={})
    assert response.status_code == 422
