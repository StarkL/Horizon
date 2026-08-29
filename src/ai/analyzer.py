"""Content analysis using AI."""
import asyncio, json, re, time
from typing import List, Optional
from .client import AIClient
from .prompts import BATCH_ANALYSIS_SYSTEM, BATCH_ANALYSIS_USER
from .utils import parse_json_response
from ..models import ContentItem

class ContentAnalyzer:
    def __init__(self, ai_client):
        self.client = ai_client

    @staticmethod
    def _parse_json_response(response):
        return parse_json_response(response)

    async def analyze_batch(self, items):
        if not items:
            return []
        # 批量 5→10：减少高频调用以降低限流/封号风险（配合下方 max_tokens 容错）
        BATCH = 10
        total = (len(items) - 1) // BATCH + 1
        print(f" Analyzing {len(items)} items in {total} batches of {BATCH}...")

        for bs in range(0, len(items), BATCH):
            batch = items[bs:bs + BATCH]
            bn = bs // BATCH + 1
            print(f"  Batch {bn}/{total}: items {bs+1}-{bs+len(batch)}")

            txt = []
            for i, item in enumerate(batch):
                m = item.metadata
                eng = []
                if m.get("score"): eng.append("score:{}".format(m["score"]))
                if m.get("descendants"): eng.append("{}cmts".format(m["descendants"]))
                eng_str = " [" + ", ".join(eng) + "]" if eng else ""
                content_snip = ""
                if item.content:
                    clean = re.sub(r"<[^>]+>", "", item.content)
                    if "--- Top Comments ---" in clean:
                        clean = clean.split("--- Top Comments ---")[0]
                    content_snip = "\n    Content: " + clean[:300]
                txt.append("[{}] {} | {} | {}{}{}".format(
                    i+1, item.id, item.title, item.source_type.value, eng_str, content_snip))

            prompt = BATCH_ANALYSIS_USER.format(count=len(batch), items="\n".join(txt))

            try:
                resp = await self.client.complete(
                    system=BATCH_ANALYSIS_SYSTEM, user=prompt, max_tokens=8192)  # 对齐 qwen-plus 输出上限，避免长批次被截断
                r = self._parse_json_response(resp)
                if not r or "results" not in r:
                    raise ValueError("parse fail")
                rl = r["results"]
                print("  OK Received {} results".format(len(rl)))
                for idx, item in enumerate(batch):
                    if idx < len(rl) and isinstance(rl[idx], dict):
                        d = rl[idx]
                        item.ai_score = float(d.get("score", 0))
                        item.ai_reason = d.get("reason", "")
                        item.ai_summary = d.get("summary", item.title)
                        item.ai_tags = d.get("tags", [])
                        if d.get("title_zh"): item.metadata["title_zh"] = d["title_zh"]
                        if d.get("summary_zh"): item.metadata["summary_zh"] = d["summary_zh"]
                    else:
                        item.ai_score = 0.0
                        item.ai_reason = "No result" if idx >= len(rl) else "Invalid format"
                        item.ai_summary = item.title
                        item.ai_tags = []
            except Exception as e:
                print("  FAIL Batch {}: {}".format(bn, e))
                for item in batch:
                    item.ai_score = 0.0
                    item.ai_reason = "Analysis failed"
                    item.ai_summary = item.title
                    item.ai_tags = []
                time.sleep(2)

        # 重试 0 分条目（API 超时/解析失败的批次）
        zero_items = [x for x in items if (x.ai_score or 0) == 0]
        if zero_items:
            print(f"\n  Retrying {len(zero_items)} zero-scored items...")
            for bs in range(0, len(zero_items), BATCH):
                batch = zero_items[bs:bs + BATCH]
                bn = bs // BATCH + 1
                print(f"  Retry Batch {bn}: items {bs+1}-{bs+len(batch)}")
                # 复用上面的评分逻辑
                txt = []
                for i, item in enumerate(batch):
                    m = item.metadata
                    eng = []
                    if m.get("score"): eng.append("score:{}".format(m["score"]))
                    if m.get("descendants"): eng.append("{}cmts".format(m["descendants"]))
                    eng_str = " [" + ", ".join(eng) + "]" if eng else ""
                    content_snip = ""
                    if item.content:
                        clean = re.sub(r"<[^>]+>", "", item.content)
                        if "--- Top Comments ---" in clean:
                            clean = clean.split("--- Top Comments ---")[0]
                        content_snip = "\n    Content: " + clean[:300]
                    txt.append("[{}] {} | {} | {}{}{}".format(
                        i+1, item.id, item.title, item.source_type.value, eng_str, content_snip))
                prompt = BATCH_ANALYSIS_USER.format(count=len(batch), items="\n".join(txt))
                try:
                    resp = await self.client.complete(
                        system=BATCH_ANALYSIS_SYSTEM, user=prompt, max_tokens=8192)
                    r = self._parse_json_response(resp)
                    if not r or "results" not in r:
                        raise ValueError("parse fail")
                    rl = r["results"]
                    print("    OK Received {} results".format(len(rl)))
                    for idx, item in enumerate(batch):
                        if idx < len(rl) and isinstance(rl[idx], dict):
                            d = rl[idx]
                            item.ai_score = float(d.get("score", 0))
                            item.ai_reason = d.get("reason", "")
                            item.ai_summary = d.get("summary", item.title)
                            item.ai_tags = d.get("tags", [])
                            if d.get("title_zh"): item.metadata["title_zh"] = d["title_zh"]
                            if d.get("summary_zh"): item.metadata["summary_zh"] = d["summary_zh"]
                except Exception as e:
                    print("    FAIL Retry Batch {}: {}".format(bn, e))
                    time.sleep(2)

        return items
