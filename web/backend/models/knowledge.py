"""Knowledge base models — shapes the on-disk reader and frontend share.

The web KB is a thin reader over the on-disk KB the CLI populates at
``~/.portoser/knowledge/`` (playbooks/*.md + problem_frequency.txt +
patterns_history/*.json). These are the only shapes that cross the
backend/frontend boundary; pre-existing PlaybookStep / PlaybookStats /
DeploymentMetrics / ProblemHistory / Search* models were dropped because
they shadowed data the reader can't actually produce from disk.
"""

from datetime import datetime
from typing import List, Optional

from pydantic import BaseModel, ConfigDict, Field


class PlaybookStats(BaseModel):
    """Per-playbook statistics derived from the markdown body + history dir."""

    occurrences: int = Field(default=0, description="Times this problem was seen")
    success_rate: float = Field(
        default=0.0, description="Solution success rate, 0.0–1.0 (single canonical scale)"
    )
    solution_pattern: Optional[str] = Field(
        default=None, description="Short identifier of the recommended solution"
    )
    last_used: Optional[datetime] = Field(
        default=None, description="When the playbook's solution was last applied"
    )


class Playbook(BaseModel):
    """A markdown playbook on disk, parsed for index/render."""

    name: str = Field(..., description="Slug — also the playbook id (filename without .md)")
    title: str = Field(..., description="First H1 in the file; falls back to ``name``")
    description: str = Field(
        default="", description="Body of the ``## Problem Description`` section"
    )
    category: str = Field(default="general", description="From frontmatter or ``general``")
    tags: List[str] = Field(default_factory=list, description="From frontmatter; default []")
    markdown_content: str = Field(
        default="", description="Full file contents — frontend renders this"
    )
    related_problems: List[str] = Field(default_factory=list)
    stats: PlaybookStats = Field(default_factory=PlaybookStats)

    model_config = ConfigDict(
        json_schema_extra={
            "example": {
                "name": "port-conflict",
                "title": "Resolve Port Conflict",
                "description": "Steps to identify and resolve port conflicts",
                "category": "troubleshooting",
                "tags": ["ports", "network"],
                "markdown_content": "# Resolve Port Conflict\n\n...",
                "related_problems": ["service_down"],
                "stats": {
                    "occurrences": 12,
                    "success_rate": 0.92,
                    "solution_pattern": "kill_and_restart",
                    "last_used": "2026-04-02T10:00:00Z",
                },
            }
        }
    )


class CommonProblem(BaseModel):
    """One row of the per-service common-problems list."""

    problem: str = Field(..., description="Problem type / fingerprint")
    count: int = Field(..., description="Occurrence count")


class ServiceInsights(BaseModel):
    """Per-service rollup from problem_frequency.txt + patterns_history/."""

    service: str = Field(..., description="Service name")
    deployment_count: int = Field(default=0)
    avg_duration_seconds: Optional[float] = Field(
        default=None,
        description="Null instead of ``N/A`` until we have a real timing source",
    )
    common_problems: List[CommonProblem] = Field(default_factory=list)
    solutions_applied: int = Field(default=0)
    reliability_score: Optional[float] = Field(
        default=None, description="Null until we have signal — never fake a value"
    )

    model_config = ConfigDict(
        json_schema_extra={
            "example": {
                "service": "webapp",
                "deployment_count": 14,
                "avg_duration_seconds": None,
                "common_problems": [{"problem": "port_conflict", "count": 5}],
                "solutions_applied": 3,
                "reliability_score": None,
            }
        }
    )


class KnowledgeStats(BaseModel):
    """Top-of-page stats. Empty KB renders cleanly with all zeros."""

    total_playbooks: int = Field(default=0)
    total_deployments: int = Field(default=0)
    total_problems: int = Field(default=0, description="Unique problem types")
    total_solutions: int = Field(default=0, description="patterns_history entry count")
    most_common_problems: List[CommonProblem] = Field(
        default_factory=list, description="Top 5 from problem_frequency.txt"
    )
    playbooks_by_category: dict[str, int] = Field(
        default_factory=dict,
        description="May be {'general': N} for v1 — frontmatter is optional",
    )

    model_config = ConfigDict(
        json_schema_extra={
            "example": {
                "total_playbooks": 3,
                "total_deployments": 25,
                "total_problems": 4,
                "total_solutions": 7,
                "most_common_problems": [{"problem": "port_conflict", "count": 5}],
                "playbooks_by_category": {"general": 3},
            }
        }
    )
