"""Locked load/save of the registry.yml file.

These wrappers existed in main.py for years; moving them to services/ lets
extracted routers import them without depending on main. Behaviour
(HTTPException-on-failure with the existing 404 / 400 / 500 mapping) is
identical to the prior inline copy.
"""

from __future__ import annotations

import logging
import os
from pathlib import Path
from typing import Dict, Optional

from fastapi import HTTPException

from services.registry_service import RegistryService

logger = logging.getLogger(__name__)

# main.py used DEFAULT_REGISTRY_PATH = repo-root/registry.yml; mirror it
# here so an unset env var picks the same file. Three parents up:
#   services/registry_helpers.py -> services/ -> backend/ -> web/ -> repo
_DEFAULT_REGISTRY_PATH = str(Path(__file__).resolve().parents[2] / "registry.yml")

_service: Optional[RegistryService] = None


def _get_service() -> RegistryService:
    """Return the (lazily-built, env-driven) RegistryService singleton."""
    global _service
    if _service is None:
        path = os.getenv("CADDY_REGISTRY_PATH", _DEFAULT_REGISTRY_PATH)
        _service = RegistryService(registry_path=path)
    return _service


def reset_for_tests() -> None:
    """Force re-resolution of the singleton.

    Test-only helper. The singleton caches the resolved path on first use,
    which is great for production but breaks tests that monkeypatch
    CADDY_REGISTRY_PATH between cases. Call this from the fixture.
    """
    global _service
    _service = None


def load_registry() -> Dict:
    """Read the registry.yml under a file lock.

    Raises HTTPException(404) if the file is missing,
    HTTPException(500) for malformed YAML or other I/O error.
    """
    try:
        return _get_service().read()
    except HTTPException:
        # FilePathValidator already raises HTTPException(404) for missing
        # files; pass it through verbatim so the original status code
        # survives. Without this, the catch-all below would rewrap it as 500.
        raise
    except FileNotFoundError:
        raise HTTPException(status_code=404, detail="Registry file not found")
    except ValueError as e:
        raise HTTPException(status_code=500, detail=f"Invalid registry: {e}")
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to load registry: {e}")


def save_registry(data: Dict) -> None:
    """Write the registry.yml atomically under a file lock.

    Raises HTTPException(400) on schema validation failures (when those are
    enforced strictly — RegistryService is currently lenient and only logs),
    HTTPException(500) for any other I/O error.
    """
    try:
        _get_service().write(data)
    except HTTPException:
        raise
    except ValueError as e:
        raise HTTPException(status_code=400, detail=f"Invalid registry data: {e}")
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to save registry: {e}")
