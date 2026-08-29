"""Generate cover image using DashScope wanx2.1-t2i-plus."""
import os, sys, requests, time, json
from pathlib import Path

def generate_cover(output_path: str, title: str = ""):
    api_key = os.environ.get('DASHSCOPE_API_KEY', '')
    if not api_key:
        print("ERROR: DASHSCOPE_API_KEY not set")
        return False

    prompt = f"科技资讯日报封面，现代简洁风格，深蓝色科技色调，抽象几何背景，适合微信公众号封面，宽屏横版，高质量，{'标题文字: ' + title if title else '无文字'}"

    headers = {
        'Authorization': f'Bearer {api_key}',
        'Content-Type': 'application/json',
        'X-DashScope-Async': 'enable'
    }
    payload = {
        'model': 'wanx2.1-t2i-plus',
        'input': {'prompt': prompt},
        'parameters': {'size': '1024*576', 'n': 1}
    }

    resp = requests.post(
        'https://dashscope.aliyuncs.com/api/v1/services/aigc/text2image/image-synthesis',
        headers=headers, json=payload, timeout=30
    )
    if resp.status_code != 200:
        print(f"Submit failed: {resp.status_code} {resp.text[:200]}")
        return False

    result = resp.json()
    task_id = result.get('output', {}).get('task_id', '')
    if not task_id:
        print(f"No task_id: {json.dumps(result, ensure_ascii=False)[:200]}")
        return False

    print(f"Task submitted: {task_id}")

    for i in range(30):
        time.sleep(5)
        check = requests.get(
            f'https://dashscope.aliyuncs.com/api/v1/tasks/{task_id}',
            headers={'Authorization': f'Bearer {api_key}'},
            timeout=30
        )
        status_data = check.json()
        task_status = status_data.get('output', {}).get('task_status', '')
        print(f"  [{i+1}] {task_status}")

        if task_status == 'SUCCEEDED':
            results = status_data['output'].get('results', [])
            if results:
                img_url = results[0].get('url', '')
                img_data = requests.get(img_url, timeout=30).content
                Path(output_path).write_bytes(img_data)
                print(f"Cover saved: {output_path} ({len(img_data)} bytes)")
                return True
        elif task_status in ('FAILED', 'CANCELED'):
            print(f"Failed: {json.dumps(status_data, ensure_ascii=False)[:300]}")
            return False

    print("Timeout")
    return False

if __name__ == '__main__':
    output = sys.argv[1] if len(sys.argv) > 1 else "cover.png"
    title = sys.argv[2] if len(sys.argv) > 2 else ""
    generate_cover(output, title)
