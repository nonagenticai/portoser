"""Knowledge base router — read-only views over the on-disk KB."""

import logging
from typing import List, Optional

from fastapi import APIRouter, Depends, HTTPException, Query

from models.knowledge import KnowledgeStats, Playbook, ServiceInsights
from services.knowledge_base import KnowledgeBase

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/knowledge", tags=["knowledge"])

# Set by services.startup.wire_routers()
knowledge_base: Optional[KnowledgeBase] = None


def get_knowledge_base() -> KnowledgeBase:
    if knowledge_base is None:
        raise HTTPException(status_code=503, detail="Knowledge base not initialized")
    return knowledge_base


@router.get("/playbooks", response_model=List[Playbook])
async def list_playbooks(
    category: Optional[str] = Query(None, description="Filter by category"),
    tag: Optional[str] = Query(None, description="Filter by tag"),
    kb: KnowledgeBase = Depends(get_knowledge_base),
):
    """List playbooks read directly from disk. Reads are always fresh
    (5s cache); the previous ``sync=`` push model is gone — the CLI
    writes the on-disk KB and the web backend reads it."""
    playbooks = kb.list_playbooks(category=category, tag=tag)
    logger.info("Listed %d playbooks (category=%s, tag=%s)", len(playbooks), category, tag)
    return playbooks


@router.get("/stats", response_model=KnowledgeStats)
async def get_knowledge_stats(kb: KnowledgeBase = Depends(get_knowledge_base)):
    """Aggregate stats across the KB. Empty directories return all-zeros."""
    return kb.get_stats()


@router.get("/playbooks/recommended/{problem_type}", response_model=List[Playbook])
async def get_recommended_playbooks(
    problem_type: str,
    service: Optional[str] = Query(None, description="Reserved for future per-service ranking"),
    kb: KnowledgeBase = Depends(get_knowledge_base),
):
    """Trivial recommender: playbooks whose ``related_problems`` mention
    this type, sorted by success_rate then occurrences. Kept so the
    pre-existing CLI/API consumers don't 404."""
    return kb.get_recommended_playbooks(problem_type=problem_type, service=service)


@router.get("/playbooks/{name}", response_model=Playbook)
async def get_playbook(name: str, kb: KnowledgeBase = Depends(get_knowledge_base)):
    """Return a single playbook including ``markdown_content`` for the
    frontend to render."""
    playbook = kb.get_playbook(name)
    if playbook is None:
        raise HTTPException(status_code=404, detail=f"Playbook not found: {name}")
    return playbook


@router.get("/insights/{service}", response_model=ServiceInsights)
async def get_service_insights(service: str, kb: KnowledgeBase = Depends(get_knowledge_base)):
    """Per-service rollup. Returns zeroed fields rather than 404 when
    the service has no recorded history yet."""
    return kb.get_service_insights(service)
