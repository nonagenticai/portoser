"""On-disk KnowledgeBase reader — fixture-driven tests.

The reader is the single source of truth shared with ``lib/knowledge/reader.sh``;
these tests pin the parsed shapes (frontmatter + regex fallback paths,
problem-frequency rollup, patterns_history counting, and an empty-KB sanity
check) so the JSON contract the frontend depends on can't drift silently.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from services.knowledge_base import KnowledgeBase

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

PLAYBOOK_WITH_FRONTMATTER = """---
title: Resolve Port Conflict
category: troubleshooting
tags: [ports, network]
related_problems: [port_conflict]
---

# Resolve Port Conflict

## Problem Description
Service fails to bind because the port is already in use.

## Solution Pattern
`stop_blocking_process_then_restart`

Occurrences: 12
Success Rate: 92%
"""

PLAYBOOK_REGEX_ONLY = """# Memory Optimization

## Problem Description
Service eating memory beyond its quota and getting OOM-killed.

Occurrences: 3
Success Rate: 67%
"""

FREQUENCY_TXT = """\
2026-04-01T10:00:00Z|port_conflict|webapp|details
2026-04-02T10:00:00Z|port_conflict|webapp|details
2026-04-02T11:00:00Z|memory|webapp|details
2026-04-03T10:00:00Z|port_conflict|api|details
"""


@pytest.fixture
def kb_dir(tmp_path: Path) -> Path:
    """Realistic on-disk KB layout with two playbooks and a frequency file."""
    knowledge_dir = tmp_path / "knowledge"
    (knowledge_dir / "playbooks").mkdir(parents=True)
    (knowledge_dir / "patterns_history").mkdir()

    (knowledge_dir / "playbooks" / "port-conflict.md").write_text(
        PLAYBOOK_WITH_FRONTMATTER, encoding="utf-8"
    )
    (knowledge_dir / "playbooks" / "memory-optimization.md").write_text(
        PLAYBOOK_REGEX_ONLY, encoding="utf-8"
    )
    (knowledge_dir / "problem_frequency.txt").write_text(FREQUENCY_TXT, encoding="utf-8")

    # Two pattern history entries, one for `webapp`, one for `api`.
    (knowledge_dir / "patterns_history" / "fp_001.json").write_text(
        json.dumps({"service": "webapp", "solution_status": "SUCCESS"}),
        encoding="utf-8",
    )
    (knowledge_dir / "patterns_history" / "fp_002.json").write_text(
        json.dumps({"service": "api", "solution_status": "FAILED"}),
        encoding="utf-8",
    )
    return knowledge_dir


@pytest.fixture
def kb(kb_dir: Path) -> KnowledgeBase:
    return KnowledgeBase(knowledge_dir=str(kb_dir))


# ---------------------------------------------------------------------------
# Playbook parsing
# ---------------------------------------------------------------------------


def test_list_playbooks_parses_frontmatter_and_regex_fallback(kb: KnowledgeBase) -> None:
    playbooks = kb.list_playbooks()
    assert {pb.name for pb in playbooks} == {"port-conflict", "memory-optimization"}

    by_name = {pb.name: pb for pb in playbooks}
    pc = by_name["port-conflict"]
    assert pc.title == "Resolve Port Conflict"
    assert pc.category == "troubleshooting"
    assert pc.tags == ["ports", "network"]
    assert pc.related_problems == ["port_conflict"]
    assert pc.stats.occurrences == 12
    assert pc.stats.success_rate == pytest.approx(0.92)
    assert pc.stats.solution_pattern == "stop_blocking_process_then_restart"
    assert "## Problem Description" in pc.markdown_content

    mem = by_name["memory-optimization"]
    assert mem.title == "Memory Optimization"  # picked up from H1 fallback
    assert mem.category == "general"  # default when frontmatter is absent
    assert mem.tags == []
    assert mem.stats.occurrences == 3
    assert mem.stats.success_rate == pytest.approx(0.67)


def test_list_playbooks_filters_by_category_and_tag(kb: KnowledgeBase) -> None:
    troubleshooting = kb.list_playbooks(category="troubleshooting")
    assert len(troubleshooting) == 1
    assert troubleshooting[0].name == "port-conflict"

    by_tag = kb.list_playbooks(tag="ports")
    assert len(by_tag) == 1
    assert by_tag[0].name == "port-conflict"

    no_match = kb.list_playbooks(tag="nonexistent")
    assert no_match == []


def test_get_playbook_returns_full_markdown(kb: KnowledgeBase) -> None:
    pb = kb.get_playbook("port-conflict")
    assert pb is not None
    assert pb.markdown_content.startswith("---")
    assert "Resolve Port Conflict" in pb.markdown_content


def test_get_playbook_rejects_path_traversal(kb: KnowledgeBase) -> None:
    assert kb.get_playbook("../etc/passwd") is None
    assert kb.get_playbook("nested/path") is None
    assert kb.get_playbook(".hidden") is None


def test_get_playbook_unknown_returns_none(kb: KnowledgeBase) -> None:
    assert kb.get_playbook("does-not-exist") is None


# ---------------------------------------------------------------------------
# Service insights
# ---------------------------------------------------------------------------


def test_service_insights_aggregates_frequency_lines(kb: KnowledgeBase) -> None:
    insights = kb.get_service_insights("webapp")
    assert insights.service == "webapp"
    assert insights.deployment_count == 3  # three lines mention `webapp`
    assert insights.solutions_applied == 1  # one history file mentions `webapp`
    problems = {p.problem: p.count for p in insights.common_problems}
    assert problems == {"port_conflict": 2, "memory": 1}
    # Empty-by-design fields stay None — not "N/A" or 1.0.
    assert insights.avg_duration_seconds is None
    assert insights.reliability_score is None


def test_service_insights_unknown_service_returns_zeros(kb: KnowledgeBase) -> None:
    insights = kb.get_service_insights("unknown-service")
    assert insights.deployment_count == 0
    assert insights.solutions_applied == 0
    assert insights.common_problems == []


# ---------------------------------------------------------------------------
# Aggregate stats
# ---------------------------------------------------------------------------


def test_get_stats_aggregates_across_files(kb: KnowledgeBase) -> None:
    stats = kb.get_stats()
    assert stats.total_playbooks == 2
    assert stats.total_deployments == 4  # frequency lines
    assert stats.total_problems == 2  # port_conflict + memory
    assert stats.total_solutions == 2  # patterns_history files
    most_common = {p.problem: p.count for p in stats.most_common_problems}
    assert most_common == {"port_conflict": 3, "memory": 1}
    assert stats.playbooks_by_category == {"troubleshooting": 1, "general": 1}


def test_empty_kb_returns_zeroed_stats(tmp_path: Path) -> None:
    """An empty / nonexistent KB must not raise — frontend renders zeros."""
    kb = KnowledgeBase(knowledge_dir=str(tmp_path / "missing"))
    stats = kb.get_stats()
    assert stats.total_playbooks == 0
    assert stats.total_deployments == 0
    assert stats.total_problems == 0
    assert stats.total_solutions == 0
    assert stats.most_common_problems == []
    assert kb.list_playbooks() == []
    assert kb.get_playbook("anything") is None
    insights = kb.get_service_insights("svc")
    assert insights.deployment_count == 0


# ---------------------------------------------------------------------------
# Recommender
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# Real CLI-emitted playbook format (markdown bold + bullet list)
# ---------------------------------------------------------------------------


PLAYBOOK_CLI_FORMAT = """# Playbook: PROBLEM_PORT_CONFLICT

## Problem Description

Port is occupied by another process, preventing service from starting.

## Statistics

- **Occurrences:** 5
- **Solutions Attempted:** 5
- **Success Rate:** 100% (5 successful, 0 failed)
- **Solution Pattern:** `port_conflict`

## Standard Operating Procedure

### 1. Observation Phase
"""


def test_parses_real_cli_playbook_format(tmp_path: Path) -> None:
    """The CLI emits stats as bullet-list bolded labels; the parser must
    tolerate ``**Occurrences:** 5`` etc. or the dashboard renders zeros
    while real history exists on disk."""
    knowledge_dir = tmp_path / "knowledge"
    (knowledge_dir / "playbooks").mkdir(parents=True)
    (knowledge_dir / "playbooks" / "PROBLEM_PORT_CONFLICT.md").write_text(
        PLAYBOOK_CLI_FORMAT, encoding="utf-8"
    )
    kb = KnowledgeBase(knowledge_dir=str(knowledge_dir))

    pb = kb.get_playbook("PROBLEM_PORT_CONFLICT")
    assert pb is not None
    assert pb.title == "Playbook: PROBLEM_PORT_CONFLICT"
    assert pb.description.startswith("Port is occupied")
    assert pb.stats.occurrences == 5
    assert pb.stats.success_rate == pytest.approx(1.0)
    assert pb.stats.solution_pattern == "port_conflict"


def test_recommended_playbooks_filters_by_related_problem(kb: KnowledgeBase) -> None:
    matches = kb.get_recommended_playbooks(problem_type="port_conflict")
    assert [pb.name for pb in matches] == ["port-conflict"]

    none = kb.get_recommended_playbooks(problem_type="not_a_real_problem")
    assert none == []
