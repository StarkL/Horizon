#!/usr/bin/env python3
"""Transform Horizon summary into blog-ready or WeChat-ready markdown.

Usage: transform_summary.py <input_file> <output_file> [--format blog|wechat]

Blog format (default):
- HTML headings with anchors for TOC navigation
- Clickable title links opening in new tab
- All content shown directly

WeChat format:
- Pure markdown headings (no HTML tags)
- Title links inline, tags replaced with original URL
- No TOC index section
- **Aggressive Sanitization**: Filters out war/politics/health rumors and softens language.
"""

import re
import sys


# WeChat-specific configuration
WECHAT_BLOCK_KEYWORDS = [
    "乌军", "俄乌", "乌克兰", "俄罗斯", "普京", "泽连斯基", "战争", "作战", "进攻",
    "英伟达", "放弃中国", "出口管制", "制裁", "脱钩",
    "抑郁", "自闭症", "癌", "肿瘤", "致死", "自杀",
    "裁员", "失业", "破产", "暴跌", "崩盘", "跑路",
    "监控", "审查", "封禁", "封杀", "涉政", "暴动", "暴乱",
]

WECHAT_BLOCK_SOURCES = [
    "zaihuapd",  # Telegram channel source for rumors
]

WECHAT_TONE_SOFTEN = [
    ("放弃", "调整"),
    ("攻击", "安全事件"),
    ("投毒", "供应链风险"),
    ("暴跌", "波动"),
    ("暴跌", "调整"),
    ("裁员", "组织优化"),
    ("封禁", "限制"),
    ("封锁", "限制"),
    ("涉黄", "违规"),
    ("涉政", "敏感"),
    ("暴乱", "冲突"),
    ("抗议", "表达诉求"),
]


def extract_score(score_str: str) -> float:
    """Extract numeric score from string like '⭐️ 8.0/10'."""
    m = re.search(r'([0-9.]+)/10', score_str)
    return float(m.group(1)) if m else 0.0


def check_wechat_safety(title: str, content: str, score_str: str) -> bool:
    """Return True if item is safe for WeChat, False if blocked."""
    combined = f"{title} {content} {score_str}"
    combined_lower = combined.lower()

    # Block by source
    for source in WECHAT_BLOCK_SOURCES:
        if source in combined_lower:
            return False

    # Block by keywords
    for kw in WECHAT_BLOCK_KEYWORDS:
        if kw in combined:
            return False

    return True


def sanitize_for_wechat(text: str) -> str:
    """Replace sensitive/aggressive words with neutral alternatives."""
    for bad, good in WECHAT_TONE_SOFTEN:
        text = text.replace(bad, good)
    return text


def transform_summary(text: str, fmt: str = "blog") -> str:
    """Transform Horizon summary into blog-ready format."""
    lines = text.split("\n")
    body_lines = lines[1:]

    result = []
    i = 0
    is_wechat = fmt == "wechat"

    while i < len(body_lines):
        line = body_lines[i]

        # Skip <a id="item-N"></a> lines
        if re.match(r'<a id="item-\d+"></a>', line.strip()):
            i += 1
            continue

        # Skip original description line in wechat mode
        if is_wechat and line.strip().startswith("> "):
            i += 1
            continue

        # Skip TOC section (## 📌 今日要闻 ... up to ---)
        if line.strip().startswith("## 📌 今日要闻"):
            # Skip until we hit the separator after TOC
            while i < len(body_lines) and body_lines[i].strip() != "---":
                i += 1
            # Skip the --- line
            if i < len(body_lines):
                i += 1
            # Also skip the original description line in wechat mode
            if is_wechat and i < len(body_lines) and body_lines[i].strip().startswith("> "):
                i += 1
            continue

        # Handle both <details open> and <details> blocks
        if line.strip() in ("<details open>", "<details>"):
            summary_line = body_lines[i + 1] if i + 1 < len(body_lines) else ""
            m = re.match(
                r'<summary>(\d+)\. \[([^\]]+)\]\(([^)]+)\) (.+)</summary>',
                summary_line,
            )
            if not m:
                result.append(line)
                i += 1
                continue

            num = m.group(1)
            title = m.group(2)
            url = m.group(3)
            score_str = m.group(4)

            # Collect content until </details>
            content_lines = []
            j = i + 2
            while j < len(body_lines):
                if body_lines[j].strip() == "</details>":
                    break
                content_lines.append(body_lines[j])
                j += 1

            # WeChat Safety Filter
            if is_wechat:
                # Check if this item should be blocked
                content_text = "\n".join(content_lines)
                if not check_wechat_safety(title, content_text, score_str):
                    i = j + 1
                    continue  # Skip this item entirely

                # Sanitize title and content
                title = sanitize_for_wechat(title)
                content_lines = [sanitize_for_wechat(cl) for cl in content_lines]

            # Remove duplicate ### heading and clean up blank lines
            cleaned = []
            for cl in content_lines:
                if cl.strip().startswith("### "):
                    heading_text = cl.strip()[4:]
                    if heading_text in title or title in heading_text:
                        continue
                cleaned.append(cl)

            # Strip leading/trailing blank lines
            while cleaned and cleaned[0].strip() == "":
                cleaned.pop(0)
            while cleaned and cleaned[-1].strip() == "":
                cleaned.pop()

            # Remove **标签**: line and replace with **原文链接**: url for WeChat
            if is_wechat:
                cleaned = [cl for cl in cleaned if not cl.strip().startswith("**标签**:")]
                cleaned.append("")
                cleaned.append(f"**原文链接**: {url}")

            # Build heading
            if is_wechat:
                # Pure markdown heading for WeChat compatibility
                result.append(
                    f'### {num}. [{title}]({url}) {score_str}\n'
                )
            else:
                # HTML heading with anchor for blog
                result.append(
                    f'<h3 id="item-{num}">{num}. <a href="{url}" target="_blank" rel="noopener noreferrer">{title}</a> {score_str}</h3>\n'
                )

            # Content shown directly (no fold)
            result.extend(cleaned)
            result.append("")

            i = j + 1
        else:
            result.append(line)
            i += 1

    return "\n".join(result)


def filter_sensitive_terms(text: str) -> str:
    """Filter politically sensitive terms for WeChat compliance."""
    replacements = [
        ("习近平", "[中国领导人]"),
    ]
    for old, new in replacements:
        text = text.replace(old, new)
    return text


def transform_for_wechat(text: str) -> str:
    """Transform summary with WeChat-specific intro."""
    result = transform_summary(text, fmt="wechat")
    intro = ""
    # Strip leading empty lines and redundant separators
    result = result.lstrip("\n")
    while result.startswith("---"):
        result = result[3:].lstrip("\n")
    while result.startswith("> ") and "条资讯" in result[:30]:
        # Skip original description line if still present
        idx = result.find("\n")
        result = result[idx+1:] if idx >= 0 else result
    # Filter sensitive terms for WeChat compliance
    result = filter_sensitive_terms(result)
    return f"{intro}\n\n---\n\n{result}"


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: transform_summary.py <input_file> [output_file] [--format blog|wechat]")
        sys.exit(1)

    input_file = sys.argv[1]
    fmt = "blog"
    output_file = None

    # Parse optional --format flag
    i = 2
    while i < len(sys.argv):
        if sys.argv[i] == "--format" and i + 1 < len(sys.argv):
            fmt = sys.argv[i + 1]
            i += 2
        elif output_file is None:
            output_file = sys.argv[i]
            i += 1
        else:
            i += 1

    with open(input_file, "r", encoding="utf-8") as f:
        content = f.read()

    transformed = transform_summary(content, fmt=fmt)

    if output_file:
        with open(output_file, "w", encoding="utf-8") as f:
            f.write(transformed)
    else:
        print(transformed, end="")
