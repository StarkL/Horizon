#!/usr/bin/env python3
"""Extract article content from ACM Queue using requests + BeautifulSoup."""

import requests
from bs4 import BeautifulSoup
import re
import sys

def extract_article(url: str):
    headers = {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36'
    }
    resp = requests.get(url, headers=headers, timeout=30)
    resp.raise_for_status()

    soup = BeautifulSoup(resp.text, 'html.parser')

    # Extract title
    title_tag = soup.find('h1') or soup.find('title')
    title = title_tag.get_text(strip=True) if title_tag else "Unknown"

    # Extract article content
    # Try common article containers
    article = soup.find('article') or soup.find(class_=re.compile(r'article|content|main', re.I))

    if article:
        elements = article.find_all(['h1', 'h2', 'h3', 'h4', 'p', 'pre', 'blockquote', 'ul', 'ol', 'figure'])
    else:
        # Fallback: get all headings and paragraphs from body
        body = soup.find('body')
        elements = body.find_all(['h1', 'h2', 'h3', 'h4', 'p', 'pre', 'blockquote', 'ul', 'ol', 'figure']) if body else []

    # Convert to markdown
    lines = []
    for el in elements:
        tag = el.name
        text = el.get_text('\n', strip=True)

        if not text:
            continue

        if tag in ('h1', 'h2', 'h3', 'h4'):
            level = int(tag[1])
            # Adjust heading level (make h1 -> h2, h2 -> h3, etc. for blog)
            new_level = min(level + 1, 6)
            lines.append(f"\n{'#' * new_level} {text}\n")
        elif tag == 'p':
            lines.append(f"\n{text}\n")
        elif tag == 'pre':
            # Code block
            code = el.find('code')
            if code:
                lines.append(f"\n```\n{code.get_text(strip=True)}\n```\n")
            else:
                lines.append(f"\n```\n{text}\n```\n")
        elif tag == 'blockquote':
            lines.append(f"\n> {text}\n")
        elif tag in ('ul', 'ol'):
            for li in el.find_all('li', recursive=False):
                lines.append(f"- {li.get_text(strip=True)}")
            lines.append("")
        elif tag == 'figure':
            figcaption = el.find('figcaption')
            if figcaption:
                lines.append(f"\n*{figcaption.get_text(strip=True)}*\n")

    return title, '\n'.join(lines)

if __name__ == "__main__":
    url = sys.argv[1] if len(sys.argv) > 1 else "https://queue.acm.org/detail.cfm?id=3807963"
    print(f"Extracting: {url}\n", file=sys.stderr)

    title, content = extract_article(url)

    print(f"# {title}\n")
    print("---\n")
    print(content)
