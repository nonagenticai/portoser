"""Smoke tests for the shared CLI runner."""

import pytest
from fastapi import HTTPException

from services.cli_runner import run_portoser_command


@pytest.mark.asyncio
async def test_runs_a_command_that_succeeds(monkeypatch):
    # /bin/echo as a stand-in CLI binary that always exists and exits 0.
    monkeypatch.setenv("PORTOSER_CLI", "/bin/echo")
    result = await run_portoser_command(["hello"], timeout=5)
    assert result["success"] is True
    assert "hello" in result["output"]
    assert result["returncode"] == 0


@pytest.mark.asyncio
async def test_command_failure_surfaces_in_returncode(monkeypatch):
    """Non-zero exit propagates as success=False without raising.

    /bin/sh -c 'exit 7' is a portable way to exercise the failure path —
    /bin/false isn't always at that path on macOS.
    """
    monkeypatch.setenv("PORTOSER_CLI", "/bin/sh")
    result = await run_portoser_command(["-c", "exit 7"], timeout=5)
    assert result["success"] is False
    assert result["returncode"] == 7


@pytest.mark.asyncio
async def test_timeout_raises_504_when_partial_disabled(monkeypatch):
    """Long-running CLI hits the timeout and surfaces as HTTP 504."""
    monkeypatch.setenv("PORTOSER_CLI", "/bin/sleep")
    with pytest.raises(HTTPException) as excinfo:
        await run_portoser_command(["10"], timeout=1, return_partial_on_timeout=False)
    assert excinfo.value.status_code == 504


@pytest.mark.asyncio
async def test_stream_callback_receives_lines(monkeypatch):
    """Streaming mode pipes each stdout line through the callback."""
    monkeypatch.setenv("PORTOSER_CLI", "/bin/echo")
    received: list[dict] = []

    async def cb(msg):
        received.append(msg)

    result = await run_portoser_command(["a-line"], stream=True, timeout=5, stream_callback=cb)
    assert result["success"] is True
    assert any("a-line" in m.get("message", "") for m in received)
