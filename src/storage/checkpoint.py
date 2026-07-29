"""Checkpoint manager for pipeline resume.

Each pipeline stage saves its output to data/checkpoints/.
On resume, the orchestrator detects the latest checkpoint
and skips already-completed stages.
"""

import json
import os
from pathlib import Path
from datetime import datetime

from ..models import ContentItem, SourceType

CHECKPOINT_DIR = Path("data/checkpoints")

# Stage order: earlier = done first
STAGES = ["fetched", "merged", "analyzed", "deduped", "final"]


def _serialize_item(item: ContentItem) -> dict:
    return {
        "id": item.id,
        "source_type": item.source_type.value,
        "title": item.title,
        "url": str(item.url),
        "content": item.content,
        "author": item.author,
        "published_at": item.published_at.isoformat() if item.published_at else None,
        "fetched_at": item.fetched_at.isoformat() if item.fetched_at else None,
        "metadata": item.metadata,
        "ai_score": item.ai_score,
        "ai_reason": item.ai_reason,
        "ai_summary": item.ai_summary,
        "ai_tags": item.ai_tags,
    }


def _deserialize_item(data: dict) -> ContentItem:
    from datetime import datetime, timezone
    item = ContentItem(
        id=data["id"],
        source_type=SourceType(data["source_type"]),
        title=data["title"],
        url=data["url"],
        content=data.get("content"),
        author=data.get("author"),
        published_at=datetime.fromisoformat(data["published_at"]) if data.get("published_at") else datetime.now(timezone.utc),
        fetched_at=datetime.fromisoformat(data["fetched_at"]) if data.get("fetched_at") else datetime.now(timezone.utc),
        metadata=data.get("metadata", {}),
        ai_score=data.get("ai_score"),
        ai_reason=data.get("ai_reason"),
        ai_summary=data.get("ai_summary"),
        ai_tags=data.get("ai_tags", []),
    )
    return item


def save_checkpoint(stage: str, items: list, extra: dict = None):
    CHECKPOINT_DIR.mkdir(parents=True, exist_ok=True)
    data = {
        "stage": stage,
        "timestamp": datetime.now().isoformat(),
        "count": len(items),
        "items": [_serialize_item(item) for item in items],
    }
    if extra:
        data["extra"] = extra
    path = CHECKPOINT_DIR / f"{stage}.json"
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)


def load_checkpoint(stage: str):
    path = CHECKPOINT_DIR / f"{stage}.json"
    if not path.exists():
        return None, None
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    items = [_deserialize_item(d) for d in data.get("items", [])]
    return items, data.get("extra")


def get_latest_stage():
    for stage in reversed(STAGES):
        if (CHECKPOINT_DIR / f"{stage}.json").exists():
            return stage
    return None


def clear_checkpoints():
    if CHECKPOINT_DIR.exists():
        for f in CHECKPOINT_DIR.iterdir():
            if f.suffix == ".json":
                f.unlink()
