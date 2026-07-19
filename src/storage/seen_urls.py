"""Persistent URL history for cross-day deduplication."""

import json
import os
from datetime import datetime, timedelta
from typing import Set


SEEN_URLS_FILE = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(__file__))), "data", "seen_urls.json")


def load_seen_urls(max_age_days: int = 90) -> Set[str]:
    """Load previously published URLs, dropping entries older than max_age_days.

    Args:
        max_age_days: Drop URLs seen before this many days ago

    Returns:
        Set of normalized URLs seen recently
    """
    if not os.path.exists(SEEN_URLS_FILE):
        return set()
    try:
        with open(SEEN_URLS_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)

        cutoff = (datetime.now() - timedelta(days=max_age_days)).isoformat()
        return {
            url for url, timestamp in data.items()
            if isinstance(timestamp, str) and timestamp >= cutoff
        }
    except (json.JSONDecodeError, KeyError):
        return set()


def save_seen_urls(seen_urls: Set[str], new_urls: Set[str]) -> None:
    """Save updated seen URLs with timestamps.

    Args:
        seen_urls: Full set of URLs to save
        new_urls: URLs added in this run (will get current timestamp)
    """
    data = {}
    now = datetime.now().isoformat()

    # Load existing data to preserve old timestamps
    if os.path.exists(SEEN_URLS_FILE):
        try:
            with open(SEEN_URLS_FILE, "r", encoding="utf-8") as f:
                data = json.load(f)
        except (json.JSONDecodeError, KeyError):
            pass

    # Update timestamps for new URLs
    for url in new_urls:
        data[url] = now

    os.makedirs(os.path.dirname(SEEN_URLS_FILE), exist_ok=True)
    with open(SEEN_URLS_FILE, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")
