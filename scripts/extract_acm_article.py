#!/usr/bin/env python3
"""Extract article from ACM Queue using Playwright and save as blog-ready markdown."""

import subprocess
import sys
from pathlib import Path

URL = "https://queue.acm.org/detail.cfm?id=3807963"
OUTPUT = "F:/document/pf/IT/projects/blog/docs/posts/other/acm-queue-article.md"

def main():
    print(f"Extracting article from: {URL}")
    print(f"Output: {OUTPUT}\n")

    # Check if playwright is installed
    try:
        subprocess.run([sys.executable, "-c", "import playwright"], check=True, capture_output=True)
    except subprocess.CalledProcessError:
        print("Installing playwright...")
        subprocess.run([sys.executable, "-m", "pip", "install", "playwright"], check=True)
        subprocess.run([sys.executable, "-m", "playwright", "install", "chromium"], check=True)
        print("Playwright installed.\n")

    # Playwright extraction code
    playwright_code = '''
from playwright.sync_api import sync_playwright
import json
import sys

url = sys.argv[1]
output = sys.argv[2]

with sync_playwright() as p:
    browser = p.chromium.launch(headless=True)
    page = browser.new_page()

    print(f"Opening: {url}")
    page.goto(url, wait_until="networkidle", timeout=30000)

    # Wait for article content
    try:
        page.wait_for_selector("article, .article, .content, main", timeout=10000)
    except:
        print("Warning: No article container found")

    # Extract title
    title = page.title()
    h1 = page.query_selector("h1")
    if h1:
        title = h1.inner_text()

    # Extract structured content
    content_json = page.evaluate("""() => {
        const result = [];
        const article = document.querySelector('article') ||
                       document.querySelector('.article') ||
                       document.querySelector('.content') ||
                       document.querySelector('main') ||
                       document.body;

        const elements = article.querySelectorAll('h1, h2, h3, h4, p, pre, blockquote, ul, ol, .references, .bibliography');

        elements.forEach(el => {
            const tag = el.tagName.toLowerCase();
            const text = el.innerText.trim();
            if (!text) return;

            if (tag.match(/^h[1-4]$/)) {
                result.push({type: 'heading', level: parseInt(tag[1]), text});
            } else if (tag === 'p') {
                result.push({type: 'paragraph', text});
            } else if (tag === 'pre') {
                const code = el.querySelector('code');
                result.push({type: 'code', text: code ? code.innerText : text});
            } else if (tag === 'blockquote') {
                result.push({type: 'quote', text});
            } else if (tag === 'ul' || tag === 'ol') {
                const items = Array.from(el.querySelectorAll('li')).map(li => li.innerText.trim());
                result.push({type: 'list', items});
            } else if (el.classList && (el.classList.contains('references') || el.classList.contains('bibliography'))) {
                result.push({type: 'heading', level: 2, text: 'References'});
                const refs = el.querySelectorAll('li, p, .ref');
                refs.forEach(ref => {
                    const refText = ref.innerText.trim();
                    if (refText) result.push({type: 'reference', text: refText});
                });
            }
        });

        return result;
    }""")

    browser.close()

    # Convert to markdown
    lines = []
    for item in content_json:
        if item['type'] == 'heading':
            new_level = min(item['level'] + 1, 6)  # h1->h2, h2->h3, etc.
            lines.append(f"\\n{'#' * new_level} {item['text']}\\n")
        elif item['type'] == 'paragraph':
            lines.append(f"\\n{item['text']}\\n")
        elif item['type'] == 'code':
            lines.append(f"\\n```\\n{item['text']}\\n```\\n")
        elif item['type'] == 'quote':
            lines.append(f"\\n> {item['text']}\\n")
        elif item['type'] == 'list':
            for li in item['items']:
                lines.append(f"- {li}")
            lines.append("")
        elif item['type'] == 'reference':
            lines.append(f"- {item['text']}")

    markdown = f"# {title}\\n\\n---\\n\\n" + "\\n".join(lines)

    with open(output, 'w', encoding='utf-8') as f:
        f.write(markdown)

    print(f"Saved to: {output}")
    print(f"Size: {len(markdown)} bytes")
'''

    # Write playwright script to temp file
    script_path = Path("/tmp/acm_extract.py")
    script_path.write_text(playwright_code)

    # Run playwright script
    result = subprocess.run(
        [sys.executable, str(script_path), URL, OUTPUT],
        capture_output=True,
        text=True
    )

    print(result.stdout)
    if result.stderr:
        print("Errors:", result.stderr)

    if Path(OUTPUT).exists():
        print(f"\\n✅ Article extracted successfully!")
        print(f"File: {OUTPUT}")
        print(f"Size: {Path(OUTPUT).stat().st_size} bytes")
    else:
        print("\\n❌ Extraction failed")

if __name__ == "__main__":
    main()
