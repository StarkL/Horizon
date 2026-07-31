"""Test content safety filter on existing summaries without modifying them."""
import asyncio, os, re, json
os.environ['PYTHONIOENCODING'] = 'utf-8'
os.environ['ANTHROPIC_API_KEY'] = os.environ.get('CODING_PLAN__API_KEY', 'proxy-managed')

from anthropic import AsyncAnthropic

SAFETY_SYSTEM = """You are a content safety reviewer for a Chinese WeChat Official Account.
Review each news item and flag content that could violate Chinese publishing regulations.

Flag as "sensitive" if the item involves:
- Chinese domestic politics or political figures
- Taiwan independence, Tibet/Xinjiang separatism
- Falun Gong or banned organizations
- Sensitive historical events (June 4 1989, Cultural Revolution)
- Criticism of Chinese government or leaders
- Territorial disputes involving China (South China Sea, etc.)
- Content that could cause social instability in China

For each item, respond with:
{"id": "<item_id>", "safe": true/false, "reason": "<explanation if flagged>"}

Content Items:
{items}

Respond with valid JSON only:
{{"results": [{{"id": "...", "safe": true/false, "reason": "..."}}]}}
"""

async def test_safety(md_file_path, label):
    from pathlib import Path
    content = Path(md_file_path).read_text(encoding='utf-8')

    # Extract items from markdown (## headings)
    items = []
    current = {}
    for line in content.split('\n'):
        m = re.match(r'^## \[?(.+?)\]?\s+([\d.]+/10)', line)
        if m:
            if current.get('title'):
                items.append(current)
            current = {'title': m.group(1).strip(), 'score': m.group(2), 'desc': ''}
        elif line.startswith('## ') and not line.startswith('###'):
            if current.get('title'):
                items.append(current)
            title = re.sub(r'\s+[\d.]+/10$', '', line[3:].strip()).strip()
            current = {'title': title, 'score': '', 'desc': ''}
        elif current.get('title') and line.strip() and not line.startswith('**') and not line.startswith('#') and not line.startswith('---') and not line.startswith('>'):
            if current['desc']:
                current['desc'] += ' ' + line.strip()
            else:
                current['desc'] = line.strip()
    if current.get('title'):
        items.append(current)

    if not items:
        print(f"  No items found in {label}")
        return

    print(f"\n{'='*60}")
    print(f"  {label}: {len(items)} items to check")
    print(f"{'='*60}")

    # Build compact items text
    items_text = []
    for i, item in enumerate(items):
        desc = item['desc'][:200] if item['desc'] else '(no description)'
        items_text.append(f"[{i+1}] {item['title']} ({item['score']})\n    {desc}")

    all_items = "\n\n".join(items_text)
    user_prompt = SAFETY_SYSTEM.replace("{items}", all_items)

    try:
        client = AsyncAnthropic(
            api_key=os.environ['ANTHROPIC_API_KEY'],
            base_url='https://coding.dashscope.aliyuncs.com/apps/anthropic',
            timeout=60.0, max_retries=0
        )
        msg = await client.messages.create(
            model='qwen3.7-plus',
            max_tokens=4000,
            system="You are a content safety reviewer for Chinese WeChat Official Account. Flag politically sensitive content.",
            messages=[{'role': 'user', 'content': user_prompt}]
        )
        text = "".join(block.text for block in msg.content if hasattr(block, 'text'))

        # Parse results
        result = json.loads(text) if text.strip().startswith('{') else None
        if not result:
            m = re.search(r'\{.*"results".*\}', text, re.DOTALL)
            if m:
                result = json.loads(m.group())

        if result and 'results' in result:
            flagged = [r for r in result['results'] if not r.get('safe', True)]
            safe_count = sum(1 for r in result['results'] if r.get('safe', True))
            print(f"\n  Results: {safe_count} safe, {len(flagged)} flagged")

            if flagged:
                print(f"\n  FLAGGED ITEMS:")
                for f in flagged:
                    print(f"    {f.get('id', '?')}: {f.get('reason', 'sensitive')}")
            else:
                print(f"\n  All items passed safety check!")
        else:
            print(f"\n  Could not parse AI response:")
            print(f"  {text[:300]}")

    except Exception as e:
        print(f"\n  Error: {type(e).__name__}: {e}")


async def main():
    base = r"F:\document\pf\IT\projects\blog\docs\posts\horizon"
    for date in ['2026-07-22', '2026-07-23']:
        md_file = f"{base}\{date}.md"
        if os.path.exists(md_file):
            await test_safety(md_file, f"{date}")
        else:
            print(f"\n  {md_file} not found")

asyncio.run(main())
