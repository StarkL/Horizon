#!/usr/bin/env python3
"""WeChat content security check using msg_sec_check API.

Reads WeChat credentials from .env, checks article content against
WeChat's moderation API, and reports any risky sections.

Usage: python check_wechat_content.py <wechat_markdown_file>
"""

import glob
import os
import re
import sys

import requests


def load_wechat_credentials(env_path: str) -> tuple[str, str]:
    """Load WECHAT_APP_ID and WECHAT_APP_SECRET from env file."""
    app_id = app_secret = None
    with open(env_path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line.startswith("WECHAT_APP_ID="):
                app_id = line.split("=", 1)[1].strip()
            elif line.startswith("WECHAT_APP_SECRET="):
                app_secret = line.split("=", 1)[1].strip()
    if not app_id or not app_secret:
        raise ValueError("WECHAT_APP_ID or WECHAT_APP_SECRET not found in .env")
    return app_id, app_secret


def get_access_token(app_id: str, app_secret: str) -> str:
    """Get WeChat access token."""
    resp = requests.get(
        "https://api.weixin.qq.com/cgi-bin/token",
        params={
            "grant_type": "client_credential",
            "appid": app_id,
            "secret": app_secret,
        },
    )
    data = resp.json()
    if "access_token" not in data:
        raise RuntimeError(f"Failed to get access token: {data}")
    return data["access_token"]


def extract_plain_text(md_content: str) -> str:
    """Strip markdown to get plain text for moderation."""
    text = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", md_content)
    text = re.sub(r"[#*`_~>|]", "", text)
    text = re.sub(r"-\s+", "", text)
    text = re.sub(r"\s+", " ", text)
    return text.strip()


def check_content(access_token: str, text: str) -> list[dict]:
    """Check content in 2000-char chunks. Return list of risky chunks."""
    risky_chunks = []
    chunks = [text[i : i + 2000] for i in range(0, len(text), 2000)]
    for i, chunk in enumerate(chunks):
        resp = requests.post(
            f"https://api.weixin.qq.com/wxa/msg_sec_check",
            params={"access_token": access_token},
            json={
                "version": 2,
                "scene": 3,
                "openid": "test",
                "content": chunk,
            },
        )
        data = resp.json()
        suggest = data.get("suggest", "unknown")
        label = data.get("label", 0)
        if suggest == "risky":
            risky_chunks.append(
                {
                    "chunk": i + 1,
                    "label": label,
                    "start": i * 2000,
                    "end": (i + 1) * 2000,
                    "preview": chunk[:200],
                }
            )
    return risky_chunks


def main():
    if len(sys.argv) < 2:
        print("Usage: python check_wechat_content.py <wechat_markdown_file>")
        sys.exit(1)

    md_file = sys.argv[1]
    if not os.path.exists(md_file):
        print(f"File not found: {md_file}")
        sys.exit(1)

    # Locate .env file - CLI arg takes priority, then baoyu-skills, then Horizon .env
    if len(sys.argv) >= 3:
        env_path = sys.argv[2]
        if not os.path.exists(env_path):
            print(f"[ContentCheck] Env file not found: {env_path}")
            sys.exit(1)
    else:
        env_paths = [
            os.path.join(os.environ.get("USERPROFILE", ""), ".baoyu-skills", ".env"),
            os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), ".env"),
        ]
        env_path = None
        for p in env_paths:
            if os.path.exists(p):
                env_path = p
                break
    if not env_path:
        print(f".env not found at any of: {env_paths}")
        sys.exit(1)
    print(f"[ContentCheck] Using .env: {env_path}")

    app_id, app_secret = load_wechat_credentials(env_path)
    print(f"[ContentCheck] AppID: {app_id}")

    access_token = get_access_token(app_id, app_secret)
    print("[ContentCheck] Access token OK")

    with open(md_file, "r", encoding="utf-8") as f:
        md_content = f.read()

    text = extract_plain_text(md_content)
    print(f"[ContentCheck] Plain text length: {len(text)} chars")

    risky_chunks = check_content(access_token, text)

    if risky_chunks:
        print(f"[ContentCheck] RISKS DETECTED: {len(risky_chunks)} chunk(s)")
        for rc in risky_chunks:
            print(f"  Chunk {rc['chunk']} (chars {rc['start']}-{rc['end']}), label={rc['label']}")
            print(f"  Preview: {rc['preview']}")
        print("[ContentCheck] RESULT: FAIL - content may violate WeChat policies")
        sys.exit(1)
    else:
        chunk_count = len([text[i:i+2000] for i in range(0, len(text), 2000)])
        print(f"[ContentCheck] RESULT: PASS - all {chunk_count} chunks are safe")
        sys.exit(0)


if __name__ == "__main__":
    main()
