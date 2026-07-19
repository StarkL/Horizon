#!/bin/bash
# VPS 端微信发布脚本（含内容安全检查）
# 用法：bash /opt/scripts/wechat-publish.sh
# 依赖：curl, jq（Alibaba Cloud Linux 已预装）
# 输入文件：
#   /tmp/wechat-config.json  - 配置（app_id, app_secret, title, author, cover_path）
#   /tmp/wechat-content.html - 渲染好的 HTML 内容
#   /tmp/wechat-cover.png    - 封面图片

set -e

CONFIG="/tmp/wechat-config.json"
HTML="/tmp/wechat-content.html"

if [ ! -f "$CONFIG" ]; then
    echo "ERROR: $CONFIG not found"
    exit 1
fi

if [ ! -f "$HTML" ]; then
    echo "ERROR: $HTML not found"
    exit 1
fi

APP_ID=$(jq -r '.app_id' "$CONFIG")
APP_SECRET=$(jq -r '.app_secret' "$CONFIG")
TITLE=$(jq -r '.title' "$CONFIG")
AUTHOR=$(jq -r '.author // empty' "$CONFIG")
COVER_PATH=$(jq -r '.cover_path // empty' "$CONFIG")

echo "Publishing to WeChat: $TITLE"

# 0. Get access_token
echo "Fetching access token..."
TOKEN_RESP=$(curl -s "https://api.weixin.qq.com/cgi-bin/token?grant_type=client_credential&appid=$APP_ID&secret=$APP_SECRET")
ACCESS_TOKEN=$(echo "$TOKEN_RESP" | jq -r '.access_token')

if [ "$ACCESS_TOKEN" = "null" ] || [ -z "$ACCESS_TOKEN" ]; then
    echo "ERROR: Failed to get access token: $TOKEN_RESP"
    exit 1
fi
echo "Access token OK"

# 1. Content security check (msg_sec_check)
echo "Running content security check..."
# Strip HTML tags to get plain text, then split into 2000-char chunks
PLAIN_TEXT=$(cat "$HTML" | sed 's/<[^>]*>//g' | sed 's/&nbsp;/ /g' | sed 's/&amp;/\&/g' | sed 's/&lt;/</g' | sed 's/&gt;/>/g' | tr -s ' \n' ' ' | head -c 50000)

CHUNK_SIZE=2000
TEXT_LEN=${#PLAIN_TEXT}
CHECK_PASSED=true
CHUNK_NUM=0

if [ "$TEXT_LEN" -gt 0 ]; then
    i=0
    while [ $i -lt $TEXT_LEN ]; do
        CHUNK_NUM=$((CHUNK_NUM + 1))
        CHUNK=$(echo "$PLAIN_TEXT" | cut -c$((i+1))-$((i+CHUNK_SIZE)))
        CHECK_RESP=$(curl -s -X POST \
            "https://api.weixin.qq.com/wxa/msg_sec_check?access_token=$ACCESS_TOKEN" \
            -H "Content-Type: application/json" \
            -d "{\"version\":2,\"scene\":3,\"openid\":\"test\",\"content\":$(echo "$CHUNK" | jq -R .)}")
        SUGGEST=$(echo "$CHECK_RESP" | jq -r '.suggest // "unknown"')
        if [ "$SUGGEST" = "risky" ]; then
            LABEL=$(echo "$CHECK_RESP" | jq -r '.label // 0')
            echo "SECURITY CHECK FAILED at chunk $CHUNK_NUM (label=$LABEL): $CHECK_RESP"
            CHECK_PASSED=false
            break
        fi
        i=$((i + CHUNK_SIZE))
    done
fi

if [ "$CHECK_PASSED" = "false" ]; then
    echo "Content security check FAILED! Skipping publish."
    rm -f "$CONFIG" "$HTML" /tmp/wechat-cover.png
    exit 1
fi
echo "Content security check PASSED ($CHUNK_NUM chunks)"

# 2. Upload cover image
THUMB_MEDIA_ID=""
if [ -n "$COVER_PATH" ] && [ -f "$COVER_PATH" ]; then
    echo "Uploading cover image..."
    COVER_RESP=$(curl -s -X POST \
        "https://api.weixin.qq.com/cgi-bin/material/add_material?access_token=$ACCESS_TOKEN&type=image" \
        -F "media=@$COVER_PATH")
    THUMB_MEDIA_ID=$(echo "$COVER_RESP" | jq -r '.media_id')
    if [ "$THUMB_MEDIA_ID" = "null" ] || [ -z "$THUMB_MEDIA_ID" ]; then
        echo "WARN: Failed to upload cover: $COVER_RESP"
    else
        echo "Cover uploaded, media_id: $THUMB_MEDIA_ID"
    fi
fi

# 3. Build JSON payload file (avoids "Argument list too long" for large HTML)
PAYLOAD="/tmp/wechat-payload.json"
jq -n \
    --arg title "$TITLE" \
    --arg author "$AUTHOR" \
    --arg thumb "${THUMB_MEDIA_ID:-}" \
    --slurpfile content <(jq -R -s . "$HTML") \
    '{
        articles: [{
            title: $title,
            author: $author,
            content: $content[0],
            thumb_media_id: $thumb
        }]
    }' > "$PAYLOAD"

# 4. Publish as draft (read from file to avoid argument length limit)
echo "Publishing draft..."
DRAFT_RESP=$(curl -s -X POST \
    "https://api.weixin.qq.com/cgi-bin/draft/add?access_token=$ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -d @"$PAYLOAD")

ERRCODE=$(echo "$DRAFT_RESP" | jq -r '.errcode // "0"')
MEDIA_ID=$(echo "$DRAFT_RESP" | jq -r '.media_id // empty')

if [ "$ERRCODE" = "0" ] && [ -n "$MEDIA_ID" ]; then
    echo "SUCCESS! Draft published. media_id: $MEDIA_ID"
else
    echo "ERROR: Failed to publish: $DRAFT_RESP"
    exit 1
fi

# Cleanup temp files
rm -f "$CONFIG" "$HTML" "$PAYLOAD" /tmp/wechat-cover.png
echo "Done."
