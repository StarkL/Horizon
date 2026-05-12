"""Daily summary generation — pure programmatic rendering."""

import re
from typing import List, Dict

from ..models import ContentItem


_CJK = r"[一-鿿㐀-䶿]"
_ASCII = r"[A-Za-z0-9]"


def _pangu(text: str) -> str:
    """Insert a space between CJK and ASCII letters/digits (Pangu spacing)."""
    text = re.sub(rf"({_CJK})({_ASCII})", r"\1 \2", text)
    text = re.sub(rf"({_ASCII})({_CJK})", r"\1 \2", text)
    return text


LABELS = {
    "en": {
        "header": "Horizon Daily",
        "source": "Source",
        "background": "Background",
        "discussion": "Discussion",
        "references": "References",
        "tags": "Tags",
        "empty_body": (
            "No significant developments today. This might indicate:\n"
            "- A quiet day in your tracked sources\n"
            "- The AI score threshold is too high\n"
            "- Your information sources need expansion\n\n"
            "Consider:\n"
            "1. Lowering the `ai_score_threshold` in config.json\n"
            "2. Adding more diverse information sources\n"
            "3. Checking if the AI model is working correctly\n"
        ),
    },
    "zh": {
        "header": "Horizon 每日速递",
        "source": "来源",
        "background": "背景",
        "discussion": "社区讨论",
        "references": "参考链接",
        "tags": "标签",
        "empty_body": (
            "今日暂无重要动态，可能原因：\n"
            "- 今天关注的信息源较平静\n"
            "- AI 评分阈值设置过高\n"
            "- 信息源种类有待扩充\n\n"
            "建议：\n"
            "1. 在 config.json 中降低 `ai_score_threshold`\n"
            "2. 添加更多多样化的信息源\n"
            "3. 检查 AI 模型是否正常工作\n"
        ),
    },
}


class DailySummarizer:
    """Generates daily Markdown summaries from pre-analyzed content items."""

    def __init__(self):
        pass

    async def generate_summary(
        self,
        items: List[ContentItem],
        date: str,
        total_fetched: int,
        language: str = "en",
    ) -> str:
        """Generate daily summary in Markdown format with three-level hierarchy.

        All items are included (no truncation). Items are sorted by ai_score
        descending. High-score items (>=6.0) default expanded; low-score (<6.0)
        default collapsed. Unreviewed items (no ai_score) go at the bottom.

        Args:
            items: Content items (already enriched with AI analysis)
            date: Date string (YYYY-MM-DD)
            total_fetched: Total number of items fetched before filtering
            language: Output language, either "en" or "zh"

        Returns:
            str: Markdown formatted summary with collapsible sections
        """
        labels = LABELS.get(language, LABELS["en"])

        if not items:
            return self._generate_empty_summary(date, total_fetched, labels)

        # Separate items: scored vs unreviewed
        scored_items = [item for item in items if item.ai_score is not None]
        unreviewed_items = [item for item in items if item.ai_score is None]

        # Sort scored items by ai_score descending
        scored_items.sort(key=lambda x: x.ai_score or 0, reverse=True)

        # Build header
        header = (
            f"# {labels['header']} - {date}\n\n"
            f"> 从 {total_fetched} 条资讯中精选 {len(items)} 条内容\n\n"
            "---\n\n"
        )

        # Build table of contents for high-score items (>= 6.0)
        high_score_count = len([i for i in scored_items if i.ai_score >= 6.0])
        toc_lines = [f"## 📌 今日要闻（{high_score_count} 条）\n"]
        toc_entries = []
        for i, item in enumerate(scored_items):
            if item.ai_score is None or item.ai_score < 6.0:
                continue
            _t = item.metadata.get(f"title_{language}") or item.title
            t = str(_t).replace("[", "(").replace("]", ")")
            if language == "zh":
                t = _pangu(t)
            score = item.ai_score or "?"
            toc_entries.append(f"- [{i + 1}. {t}](#item-{i + 1}) ⭐️ {score}/10")
        toc_lines.append("\n".join(toc_entries))
        toc_lines.append("\n---\n")
        toc = "\n".join(toc_lines)

        # Format each scored item
        parts = []
        for i, item in enumerate(scored_items):
            parts.append(self._format_item_hierarchical(item, labels, language, i + 1))

        # Format unreviewed items section
        if unreviewed_items:
            unreviewed_lines = [
                f"## 📂 原始数据（{len(unreviewed_items)} 条）\n",
                "<details>",
                "<summary>未分类条目（点击展开）</summary>\n",
            ]
            for item in unreviewed_items:
                _t = item.metadata.get(f"title_{language}") or item.title
                t = str(_t).replace("[", "(").replace("]", ")")
                if language == "zh":
                    t = _pangu(t)
                source_type = item.source_type.value
                source_parts = [source_type]
                if item.metadata.get("subreddit"):
                    source_parts.append(f"r/{item.metadata['subreddit']}")
                if item.metadata.get("feed_name"):
                    source_parts.append(item.metadata["feed_name"])
                else:
                    source_parts.append(item.author or "unknown")
                source_line = " · ".join(source_parts)
                unreviewed_lines.append(f"- [{t}]({item.url}) · {source_line}")
            unreviewed_lines.append("\n</details>")
            parts.append("\n" + "\n".join(unreviewed_lines))

        return header + toc + "\n".join(parts)

    def generate_webhook_overview(
        self,
        items: List[ContentItem],
        date: str,
        total_fetched: int,
        language: str = "en",
    ) -> str:
        """Generate a compact overview for multi-message webhook delivery."""
        labels = LABELS.get(language, LABELS["en"])
        if not items:
            return self._generate_empty_summary(date, total_fetched, labels)

        if language == "zh":
            header = (
                f"# {labels['header']} - {date}\n\n"
                f"> 从 {total_fetched} 条内容中筛选出 {len(items)} 条重要资讯。\n\n"
                "下面会按新闻逐条发送详情，你可以只看感兴趣的标题。\n\n"
            )
        else:
            header = (
                f"# {labels['header']} - {date}\n\n"
                f"> Selected {len(items)} important items from {total_fetched} fetched items.\n\n"
                "Details will be sent item by item so you can read only the topics you care about.\n\n"
            )

        entries = []
        for i, item in enumerate(items, start=1):
            title = str(item.metadata.get(f"title_{language}") or item.title).replace("[", "(").replace("]", ")")
            if language == "zh":
                title = _pangu(title)
            score = item.ai_score or "?"
            entries.append(f"{i}. [{title}]({item.url}) ⭐️ {score}/10")

        return header + "\n".join(entries)

    def generate_webhook_item(
        self,
        item: ContentItem,
        language: str,
        index: int,
        total: int,
    ) -> str:
        """Generate one item message for multi-message webhook delivery."""
        labels = LABELS.get(language, LABELS["en"])
        prefix = f"第 {index}/{total} 条\n\n" if language == "zh" else f"Item {index}/{total}\n\n"
        return prefix + self._format_item(item, labels, language, index).rstrip("-\n ")

    def _format_item_hierarchical(self, item: ContentItem, labels: dict, language: str, index: int) -> str:
        """Format a single ContentItem into a collapsible hierarchical Markdown block.

        Uses <details> tags with 'open' attribute for items >= 6.0 score.
        """
        score = item.ai_score or 0
        is_high_score = score >= 6.0

        # Title: prefer long version for blog display
        display_title = item.metadata.get("title_zh_long") or item.metadata.get("title_zh") or item.title
        if language == "zh":
            display_title = _pangu(str(display_title))
        display_title = str(display_title).replace("[", "(").replace("]", ")")

        # Summary: prefer long version for blog display
        summary = (
            item.metadata.get("summary_zh_long")
            or item.metadata.get("detailed_summary_zh")
            or item.metadata.get("summary_zh")
            or item.ai_summary
            or ""
        )
        if language == "zh":
            summary = _pangu(summary)

        # Source line
        source_type = item.source_type.value
        source_parts = [source_type]
        meta = item.metadata
        if meta.get("subreddit"):
            source_parts.append(f"r/{meta['subreddit']}")
        if meta.get("feed_name"):
            source_parts.append(meta["feed_name"])
        else:
            source_parts.append(item.author or "unknown")
        if item.published_at:
            day = item.published_at.strftime("%d").lstrip("0")
            source_parts.append(item.published_at.strftime(f"%b {day}, %H:%M"))
        source_line = " · ".join(source_parts)

        # Determine details open attribute
        details_open = ' open' if is_high_score else ''

        lines = [
            f'<a id="item-{index}"></a>',
            f"<details{details_open}>",
            f'<summary>{index}. [{display_title}]({item.url}) ⭐️ {score}/10</summary>',
            "",
            f"### {display_title}",
            "",
            summary,
            "",
            f"**{labels['source']}**: {source_line}",
        ]

        background = meta.get("background_zh") or meta.get("background") or ""
        if background:
            lines.append("")
            lines.append(f"**{labels['background']}**: {background}")

        sources = meta.get("sources") or []
        if sources:
            items_html = "".join(f'<li><a href="{s["url"]}">{s["title"]}</a></li>\n' for s in sources)
            lines += [
                "",
                f'<details><summary>{labels["references"]}</summary>\n<ul>\n{items_html}\n</ul>\n</details>',
            ]

        discussion = meta.get("community_discussion_zh") or meta.get("community_discussion") or ""
        if discussion:
            lines.append("")
            lines.append(f"**{labels['discussion']}**: {discussion}")

        if item.ai_tags:
            tags_str = ", ".join([f"`#{t}`" for t in item.ai_tags])
            lines.append("")
            lines.append(f"**{labels['tags']}**: {tags_str}")

        lines += [
            "",
            "</details>",
            "",
            "---",
            "",
        ]

        return "\n".join(lines)

    def _format_item(self, item: ContentItem, labels: dict, language: str, index: int) -> str:
        """Format a single ContentItem into Markdown."""
        _title = item.metadata.get(f"title_{language}") or item.title
        title = str(_title).replace("[", "(").replace("]", ")")
        url = str(item.url)
        score = item.ai_score or "?"
        meta = item.metadata

        summary = (
            meta.get(f"detailed_summary_{language}")
            or meta.get("detailed_summary")
            or meta.get("summary_zh")  # From analyzer step
            or item.ai_summary
            or ""
        )
        background = meta.get(f"background_{language}") or meta.get("background") or ""
        discussion = (
            meta.get(f"community_discussion_{language}")
            or meta.get("community_discussion")
            or ""
        )

        if language == "zh":
            title = _pangu(title)
            summary = _pangu(summary)
            background = _pangu(background)
            discussion = _pangu(discussion)

        # Source line with parts joined by " · ", link appended at end
        source_type = item.source_type.value
        source_parts = [source_type]
        if meta.get("subreddit"):
            source_parts.append(f"r/{meta['subreddit']}")
        if meta.get("feed_name"):
            source_parts.append(meta["feed_name"])
        else:
            source_parts.append(item.author or "unknown")
        if item.published_at:
            day = item.published_at.strftime("%d").lstrip("0")
            source_parts.append(item.published_at.strftime(f"%b {day}, %H:%M"))
        source_line = " · ".join(source_parts)  # ·

        lines = [
            f'<a id="item-{index}"></a>',
            f"## [{title}]({url}) ⭐️ {score}/10",  # ⭐️
            "",
            summary,
            "",
            source_line,
        ]

        if background:
            lines.append("")
            lines.append(f"**{labels['background']}**: {background}")

        sources = meta.get("sources") or []
        if sources:
            items_html = "".join(f'<li><a href="{s["url"]}">{s["title"]}</a></li>\n' for s in sources)
            lines += [
                "",
                f'<details><summary>{labels["references"]}</summary>\n<ul>\n{items_html}\n</ul>\n</details>',
            ]

        if discussion:
            lines.append("")
            lines.append(f"**{labels['discussion']}**: {discussion}")

        if item.ai_tags:
            tags_str = ", ".join([f"`#{t}`" for t in item.ai_tags])
            lines.append("")
            lines.append(f"**{labels['tags']}**: {tags_str}")

        lines.append("")
        lines.append("---")

        return "\n".join(lines) + "\n\n"

    def _generate_empty_summary(self, date: str, total_fetched: int, labels: dict) -> str:
        """Generate summary when no high-scoring items were found."""
        return (
            f"# {labels['header']} - {date}\n\n"
            f"> Analyzed {total_fetched} items, but none met the importance threshold.\n\n"
            + labels["empty_body"]
        )
