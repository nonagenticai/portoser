"""Shared async wrapper around the portoser CLI binary.

The same function used to live both in main.py and routers/certificates.py
with two slightly-different copies. This is the single canonical impl —
both call sites now go through it.
"""

from __future__ import annotations

import asyncio
import logging
import os
from pathlib import Path
from typing import Any, Awaitable, Callable, Dict, List, Optional

from fastapi import HTTPException

logger = logging.getLogger(__name__)

# Mirror main.py's resolution path: services/cli_runner.py -> services/ ->
# backend/ -> web/ -> repo. Override with PORTOSER_CLI env var.
_DEFAULT_PORTOSER_CLI = str(Path(__file__).resolve().parents[2] / "portoser")

StreamCallback = Callable[[Dict[str, Any]], Awaitable[None]]


def _portoser_cli_path() -> str:
    return os.getenv("PORTOSER_CLI", _DEFAULT_PORTOSER_CLI)


async def _kill_process_quietly(process) -> None:
    if process is None or process.returncode is not None:
        return
    try:
        process.kill()
        await asyncio.wait_for(process.wait(), timeout=2)
    except Exception:
        pass


async def run_portoser_command(
    args: List[str],
    stream: bool = False,
    timeout: int = 60,
    return_partial_on_timeout: bool = True,
    stream_callback: Optional[StreamCallback] = None,
) -> Dict[str, Any]:
    """Run the portoser CLI with the given args.

    Args:
        args: CLI command arguments (e.g. ``["start", "myservice"]``).
        stream: When True, read stdout line-by-line and forward each line
            through ``stream_callback`` (typically a WebSocket broadcaster).
            When False, capture stdout/stderr in one go.
        timeout: Hard cap on total CLI runtime, in seconds.
        return_partial_on_timeout: If the CLI times out, attempt to return
            whatever partial output we have rather than raising 504.
        stream_callback: Async callable invoked once per output line when
            ``stream`` is True. Used to be ``broadcast_message`` from
            main.py; left as a parameter so callers stay decoupled from
            the WebSocketManager.

    Returns:
        ``{"success": bool, "output": str, "error": Optional[str],
            "returncode": int}``

    Raises:
        HTTPException(504) on timeout when ``return_partial_on_timeout`` is
            False or there's no partial output to return.
        HTTPException(500) on unexpected exec failures.
    """
    cmd = [_portoser_cli_path()] + args
    process = None

    try:
        if stream:
            process = await asyncio.create_subprocess_exec(
                *cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
            )
            output_lines: List[str] = []

            try:

                async def _read_stream() -> None:
                    async for line in process.stdout:
                        decoded = line.decode().strip()
                        output_lines.append(decoded)
                        if stream_callback is not None:
                            await stream_callback({"type": "deployment_log", "message": decoded})

                await asyncio.wait_for(_read_stream(), timeout=timeout)
                await asyncio.wait_for(process.wait(), timeout=5)
                stderr = await process.stderr.read()
                return {
                    "success": process.returncode == 0,
                    "output": "\n".join(output_lines),
                    "error": stderr.decode() if stderr else None,
                    "returncode": process.returncode,
                }

            except asyncio.TimeoutError:
                logger.error(f"Streaming CLI command timed out after {timeout}s: {args}")
                await _kill_process_quietly(process)
                if return_partial_on_timeout and output_lines:
                    return {
                        "success": False,
                        "output": "\n".join(output_lines) + "\n[TIMEOUT - Partial output]",
                        "error": f"Command timed out after {timeout}s",
                        "returncode": -1,
                    }
                raise HTTPException(status_code=504, detail=f"Command timed out after {timeout}s")

        # Non-streaming path
        process = await asyncio.create_subprocess_exec(
            *cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
        )
        try:
            stdout, stderr = await asyncio.wait_for(process.communicate(), timeout=timeout)
            return {
                "success": process.returncode == 0,
                "output": stdout.decode(),
                "error": stderr.decode() if process.returncode != 0 else None,
                "returncode": process.returncode,
            }

        except asyncio.TimeoutError:
            logger.error(f"CLI command timed out after {timeout}s: {args}")
            await _kill_process_quietly(process)
            if return_partial_on_timeout:
                try:
                    partial_stdout = await asyncio.wait_for(process.stdout.read(), timeout=1)
                    if partial_stdout:
                        return {
                            "success": False,
                            "output": partial_stdout.decode() + "\n[TIMEOUT - Partial output]",
                            "error": f"Command timed out after {timeout}s",
                            "returncode": -1,
                        }
                except Exception:
                    pass
            raise HTTPException(status_code=504, detail=f"Command timed out after {timeout}s")

    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"CLI command failed: {e}")
        await _kill_process_quietly(process)
        raise HTTPException(status_code=500, detail=f"Command failed: {str(e)}")
