"""API routers for Portoser Web Backend"""

from .auth import router as auth_router
from .certificates import router as certificates_router
from .cluster import router as cluster_router
from .config import router as config_router
from .dependencies import router as dependencies_router
from .deployment import router as deployment_router
from .devices import router as devices_router
from .devices_metrics import router as devices_metrics_router
from .diagnostics import router as diagnostics_router
from .health import router as health_router
from .history import router as history_router
from .knowledge import router as knowledge_router
from .machines import router as machines_router
from .mcp import router as mcp_router
from .prometheus import router as prometheus_router
from .services_admin import router as services_admin_router
from .status import router as status_router
from .vault import router as vault_router

__all__ = [
    "auth_router",
    "deployment_router",
    "diagnostics_router",
    "health_router",
    "knowledge_router",
    "vault_router",
    "dependencies_router",
    "history_router",
    "mcp_router",
    "certificates_router",
    "devices_router",
    "devices_metrics_router",
    "config_router",
    "cluster_router",
    "machines_router",
    "prometheus_router",
    "services_admin_router",
    "status_router",
]
