"""Knowledge base — thin reader over the on-disk KB the CLI populates.

The CLI writes ``~/.portoser/knowledge/`` (``playbooks/*.md``,
``problem_frequency.txt``, ``patterns_history/*.json``); this module reads
that same layout, so the web UI and the CLI agree on a single source of
truth without a separate database or sync pipeline. ``lib/knowledge/reader.sh``
is the bash counterpart — keep parsing heuristics aligned with it.
"""

from __future__ import annotations

import glob
import json
import logging
import os
import re
import time
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

from models.knowledge import (
    CommonProblem,
    KnowledgeStats,
    Playbook,
    PlaybookStats,
    ServiceInsights,
)

logger = logging.getLogger(__name__)

# Cache reads for 5s — file-stat-based; the dashboard makes a few requests
# per page and we don't want to re-glob/re-parse on every keystroke.
_CACHE_TTL_SECONDS = 5.0

_FRONTMATTER_RE = re.compile(r"\A---\s*\n(.*?)\n---\s*\n(.*)\Z", re.DOTALL)
_H1_RE = re.compile(r"^#\s+(.+)$", re.MULTILINE)
_PROBLEM_DESC_RE = re.compile(
    r"^##\s+Problem\s+Description\s*\n+([^\n]+)", re.MULTILINE | re.IGNORECASE
)
# Real CLI-emitted playbooks use markdown bold ("**Occurrences:** 5"); the
# patterns below tolerate any non-digit / non-newline run between label and
# value so we don't have to special-case asterisks, colons, or unicode dashes.
_SUCCESS_RATE_RE = re.compile(r"Success\s+Rate[^\n%]*?(\d+)\s*%", re.IGNORECASE)
_OCCURRENCES_RE = re.compile(r"Occurrences[^\n\d]*(\d+)", re.IGNORECASE)
# Accept "Solution Pattern: `name`" (inline) or "## Solution Pattern" +
# a backtick-quoted value on a following line — both shapes appear in
# the bash reader's source format.
_SOLUTION_PATTERN_RE = re.compile(r"Solution\s+Pattern[^`\n]*?\n?\s*`([^`]+)`", re.IGNORECASE)


def _parse_frontmatter(raw: str) -> Tuple[Dict[str, Any], str]:
    """Split ``---\\nyaml\\n---\\nbody`` into ``(metadata, body)``.

    YAML is parsed manually with a flat ``key: value`` reader plus list
    short-form ``[a, b]``, which covers the playbook frontmatter shapes the
    CLI emits without dragging PyYAML into the dependency surface.
    """
    match = _FRONTMATTER_RE.match(raw)
    if not match:
        return {}, raw

    fm_text, body = match.group(1), match.group(2)
    meta: Dict[str, Any] = {}
    for line in fm_text.splitlines():
        line = line.rstrip()
        if not line or line.startswith("#"):
            continue
        if ":" not in line:
            continue
        key, _, value = line.partition(":")
        key = key.strip()
        value = value.strip()
        if value.startswith("[") and value.endswith("]"):
            inner = value[1:-1].strip()
            meta[key] = (
                [item.strip().strip("'\"") for item in inner.split(",") if item.strip()]
                if inner
                else []
            )
        elif (value.startswith('"') and value.endswith('"')) or (
            value.startswith("'") and value.endswith("'")
        ):
            meta[key] = value[1:-1]
        else:
            meta[key] = value
    return meta, body


def _parse_playbook(path: Path) -> Playbook:
    """Parse one playbook file into a Playbook model.

    YAML frontmatter is preferred when present; the regex heuristics from
    ``reader.sh`` are the fallback so existing on-disk playbooks (which
    don't ship frontmatter) still produce sane stats.
    """
    name = path.stem
    raw = path.read_text(encoding="utf-8", errors="replace")
    meta, body = _parse_frontmatter(raw)

    if not meta:
        logger.debug("Playbook %s has no frontmatter; using regex heuristics", name)

    h1_match = _H1_RE.search(body)
    title = meta.get("title") or (h1_match.group(1).strip() if h1_match else name)

    description = meta.get("description", "")
    if not description:
        desc_match = _PROBLEM_DESC_RE.search(body)
        if desc_match:
            description = desc_match.group(1).strip()

    category = meta.get("category", "general") or "general"
    raw_tags = meta.get("tags", [])
    tags = raw_tags if isinstance(raw_tags, list) else [raw_tags]

    raw_related = meta.get("related_problems", [])
    related_problems = raw_related if isinstance(raw_related, list) else [raw_related]

    occurrences = 0
    occ_match = _OCCURRENCES_RE.search(body)
    if occ_match:
        occurrences = int(occ_match.group(1))
    elif "occurrences" in meta:
        try:
            occurrences = int(meta["occurrences"])
        except (TypeError, ValueError):
            occurrences = 0

    success_rate = 0.0
    sr_match = _SUCCESS_RATE_RE.search(body)
    if sr_match:
        success_rate = int(sr_match.group(1)) / 100.0
    elif "success_rate" in meta:
        try:
            raw_sr = float(meta["success_rate"])
            success_rate = raw_sr / 100.0 if raw_sr > 1.0 else raw_sr
        except (TypeError, ValueError):
            success_rate = 0.0

    sp_match = _SOLUTION_PATTERN_RE.search(body)
    solution_pattern: Optional[str] = sp_match.group(1).strip() if sp_match else None

    mtime = datetime.fromtimestamp(path.stat().st_mtime, tz=timezone.utc)

    return Playbook(
        name=name,
        title=title,
        description=description,
        category=category,
        tags=tags,
        markdown_content=raw,
        related_problems=related_problems,
        stats=PlaybookStats(
            occurrences=occurrences,
            success_rate=success_rate,
            solution_pattern=solution_pattern,
            last_used=mtime if occurrences > 0 else None,
        ),
    )


class KnowledgeBase:
    """Stateless reader over the on-disk knowledge base.

    Construct once at startup with ``knowledge_dir`` pointing at the same
    directory the CLI writes (env: ``KNOWLEDGE_BASE_DIR``). All public
    methods re-read from disk through a small TTL cache.
    """

    def __init__(self, knowledge_dir: Optional[str] = None):
        resolved = (
            knowledge_dir
            or os.getenv("KNOWLEDGE_BASE_DIR")
            or os.getenv("KNOWLEDGE_BASE_PATH")
            or os.path.expanduser("~/.portoser/knowledge")
        )
        self.knowledge_dir = Path(resolved).expanduser()
        self.playbooks_dir = self.knowledge_dir / "playbooks"
        self.patterns_history_dir = self.knowledge_dir / "patterns_history"
        self.frequency_file = self.knowledge_dir / "problem_frequency.txt"
        self._cache: Dict[str, Tuple[float, Any]] = {}
        logger.info("KnowledgeBase reader rooted at %s", self.knowledge_dir)

    # ---- caching --------------------------------------------------------

    def _cache_get(self, key: str) -> Any:
        entry = self._cache.get(key)
        if entry is None:
            return None
        ts, value = entry
        if time.monotonic() - ts > _CACHE_TTL_SECONDS:
            return None
        return value

    def _cache_set(self, key: str, value: Any) -> None:
        self._cache[key] = (time.monotonic(), value)

    # ---- playbooks ------------------------------------------------------

    def list_playbooks(
        self, category: Optional[str] = None, tag: Optional[str] = None
    ) -> List[Playbook]:
        cache_key = f"playbooks:{category}:{tag}"
        cached = self._cache_get(cache_key)
        if cached is not None:
            return cached

        playbooks: List[Playbook] = []
        if self.playbooks_dir.is_dir():
            for path_str in sorted(glob.glob(str(self.playbooks_dir / "*.md"))):
                path = Path(path_str)
                try:
                    playbooks.append(_parse_playbook(path))
                except Exception as exc:
                    logger.warning("Failed to parse playbook %s: %s", path, exc)

        if category:
            playbooks = [p for p in playbooks if p.category == category]
        if tag:
            playbooks = [p for p in playbooks if tag in p.tags]

        playbooks.sort(
            key=lambda p: (p.stats.occurrences, p.stats.success_rate),
            reverse=True,
        )
        self._cache_set(cache_key, playbooks)
        return playbooks

    def get_playbook(self, name: str) -> Optional[Playbook]:
        # Cheap path-traversal guard: the CLI uses simple slugs, so no
        # legitimate playbook contains '/' or '..'.
        if "/" in name or ".." in name or name.startswith("."):
            return None
        path = self.playbooks_dir / f"{name}.md"
        if not path.is_file():
            return None
        try:
            return _parse_playbook(path)
        except Exception as exc:
            logger.warning("Failed to parse playbook %s: %s", path, exc)
            return None

    # ---- service insights ----------------------------------------------

    def _read_frequency_lines(self) -> List[str]:
        cached = self._cache_get("frequency_lines")
        if cached is not None:
            return cached
        if not self.frequency_file.is_file():
            self._cache_set("frequency_lines", [])
            return []
        try:
            lines = [
                line.rstrip("\n")
                for line in self.frequency_file.read_text(
                    encoding="utf-8", errors="replace"
                ).splitlines()
                if line.strip()
            ]
        except OSError as exc:
            logger.warning("Could not read %s: %s", self.frequency_file, exc)
            lines = []
        self._cache_set("frequency_lines", lines)
        return lines

    def _patterns_for_service(self, service: str) -> int:
        if not self.patterns_history_dir.is_dir():
            return 0
        count = 0
        marker = f'"service": "{service}"'
        for path_str in glob.glob(str(self.patterns_history_dir / "*.json")):
            try:
                with open(path_str, encoding="utf-8", errors="replace") as fh:
                    if marker in fh.read():
                        count += 1
            except OSError:
                continue
        return count

    def get_service_insights(self, service: str) -> ServiceInsights:
        cache_key = f"insights:{service}"
        cached = self._cache_get(cache_key)
        if cached is not None:
            return cached

        deployment_count = 0
        problem_counts: Counter[str] = Counter()
        for line in self._read_frequency_lines():
            # Format: "<timestamp>|<problem>|<service>|..."
            parts = line.split("|")
            if len(parts) >= 3 and parts[2] == service:
                deployment_count += 1
                problem_counts[parts[1]] += 1

        common_problems = [
            CommonProblem(problem=problem, count=count)
            for problem, count in problem_counts.most_common(5)
        ]
        insights = ServiceInsights(
            service=service,
            deployment_count=deployment_count,
            avg_duration_seconds=None,
            common_problems=common_problems,
            solutions_applied=self._patterns_for_service(service),
            reliability_score=None,
        )
        self._cache_set(cache_key, insights)
        return insights

    # ---- aggregate stats -----------------------------------------------

    def get_stats(self) -> KnowledgeStats:
        cached = self._cache_get("stats")
        if cached is not None:
            return cached

        playbooks = self.list_playbooks()
        playbooks_by_category: Dict[str, int] = {}
        for pb in playbooks:
            playbooks_by_category[pb.category] = playbooks_by_category.get(pb.category, 0) + 1

        problem_counts: Counter[str] = Counter()
        total_deployments = 0
        for line in self._read_frequency_lines():
            parts = line.split("|")
            if len(parts) >= 2:
                problem_counts[parts[1]] += 1
                total_deployments += 1

        most_common_problems = [
            CommonProblem(problem=problem, count=count)
            for problem, count in problem_counts.most_common(5)
        ]

        total_solutions = 0
        if self.patterns_history_dir.is_dir():
            total_solutions = len(glob.glob(str(self.patterns_history_dir / "*.json")))

        stats = KnowledgeStats(
            total_playbooks=len(playbooks),
            total_deployments=total_deployments,
            total_problems=len(problem_counts),
            total_solutions=total_solutions,
            most_common_problems=most_common_problems,
            playbooks_by_category=playbooks_by_category,
        )
        self._cache_set("stats", stats)
        return stats

    # ---- recommender (trivial) -----------------------------------------

    def get_recommended_playbooks(
        self, problem_type: str, service: Optional[str] = None
    ) -> List[Playbook]:
        """Filter playbooks whose ``related_problems`` mention this type.

        Sorted by ``stats.success_rate`` then ``stats.occurrences`` — the
        v1 recommender from the plan. ``service`` is accepted for API
        compatibility but not used until we have per-service success data.
        """
        del service  # unused in v1; reserved for future per-service ranking
        matches = [pb for pb in self.list_playbooks() if problem_type in pb.related_problems]
        matches.sort(
            key=lambda p: (p.stats.success_rate, p.stats.occurrences),
            reverse=True,
        )
        return matches

    # ---- legacy json-history loader (kept for tests) -------------------

    def patterns_history_count(self) -> int:
        if not self.patterns_history_dir.is_dir():
            return 0
        return len(glob.glob(str(self.patterns_history_dir / "*.json")))

    def patterns_history_iter(self):
        """Yield parsed pattern history entries; tolerates malformed files."""
        if not self.patterns_history_dir.is_dir():
            return
        for path_str in glob.glob(str(self.patterns_history_dir / "*.json")):
            try:
                with open(path_str, encoding="utf-8", errors="replace") as fh:
                    yield json.load(fh)
            except (OSError, json.JSONDecodeError) as exc:
                logger.debug("Skipping unreadable history entry %s: %s", path_str, exc)
