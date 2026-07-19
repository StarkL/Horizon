// 本地渲染脚本：markdown → WeChat HTML
// Usage: bun render-wechat.ts <input.md> <output.html> [title] [theme] [color]

import fs from "node:fs";
import { execFileSync } from "node:child_process";

const mdToWechatScript = "C:/Users/Administrator/.claude/skills/baoyu-post-to-wechat/scripts/md-to-wechat.ts";

async function main() {
  const inputMd = process.argv[2];
  const outputHtml = process.argv[3];
  const title = process.argv[4] || "";
  const theme = process.argv[5] || "grace";
  const color = process.argv[6] || "blue";

  if (!inputMd || !outputHtml) {
    process.stderr.write("Usage: bun render-wechat.ts <input.md> <output.html> [title] [theme] [color]\n");
    process.exit(1);
  }

  // Call md-to-wechat to render
  let stdout: string;
  try {
    stdout = execFileSync("npx", [
      "-y", "bun", mdToWechatScript, inputMd,
      "--title", title,
      "--theme", theme,
      "--color", color,
      "--no-cite",
    ], { encoding: "utf-8" });
  } catch (e) {
    process.stderr.write(`Render command failed: ${e}\n`);
    process.exit(1);
  }

  // Find the JSON block (starts with { ends with })
  const jsonStart = stdout.indexOf("{");
  const jsonEnd = stdout.lastIndexOf("}");
  if (jsonStart === -1 || jsonEnd === -1 || jsonEnd <= jsonStart) {
    process.stderr.write(`Render failed, no JSON found in output: ${stdout}\n`);
    process.exit(1);
  }

  const jsonStr = stdout.slice(jsonStart, jsonEnd + 1);
  let result: Record<string, string>;
  try {
    result = JSON.parse(jsonStr) as Record<string, string>;
  } catch {
    process.stderr.write(`Render failed, could not parse JSON: ${jsonStr}\n`);
    process.exit(1);
  }

  if (!result.htmlPath) {
    process.stderr.write(`Render failed, no htmlPath in result: ${JSON.stringify(result)}\n`);
    process.exit(1);
  }

  const htmlPath = result.htmlPath;
  if (fs.existsSync(htmlPath)) {
    const html = fs.readFileSync(htmlPath, "utf-8");
    fs.writeFileSync(outputHtml, html, "utf-8");
    process.stdout.write(`HTML rendered: ${outputHtml} (${html.length} chars)\n`);
  } else {
    process.stderr.write(`HTML file not found: ${htmlPath}\n`);
    process.exit(1);
  }
}

main().catch((err) => {
  process.stderr.write(`Error: ${err instanceof Error ? err.message : String(err)}\n`);
  process.exit(1);
});
