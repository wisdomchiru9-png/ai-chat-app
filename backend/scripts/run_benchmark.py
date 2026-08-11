"""
AI Chat — Standalone LLM benchmark / evaluation script.

Matches the role requirement:
  "Evaluate and optimize machine learning models with LLM evaluation,
   NLP, Node.js, Python, and Hugging Face."

It calls POST /benchmark on the FastAPI backend and prints a nicely formatted
table of results + recommendation, optionally saving JSON and Markdown reports
to ./reports/.

Run (after backend is running):
    python -m scripts.run_benchmark --save reports/

Or if backend is not running yet, pass --start to spawn uvicorn as subprocess.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from datetime import datetime
from pathlib import Path

import urllib.request
import urllib.error

BACKEND_URL = os.getenv("BACKEND_URL", "http://localhost:8000")


def post_json(path: str, body: dict, timeout: int = 600) -> dict:
    req = urllib.request.Request(
        f"{BACKEND_URL}/{path.lstrip('/')}",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode())


def wait_for_backend(timeout_s: int = 120) -> bool:
    t0 = time.time()
    while time.time() - t0 < timeout_s:
        try:
            with urllib.request.urlopen(f"{BACKEND_URL}/", timeout=5) as r:
                if r.status == 200:
                    return True
        except (urllib.error.URLError, OSError):
            pass
        print(".", end="", flush=True)
        time.sleep(3)
    return False


def print_table(results: list[dict]) -> None:
    headers = ["provider", "model", "score", "avg ms", "p95 ms", "sent_acc", "quality", "cost $"]
    rows = []
    for r in results:
        rows.append([
            r["provider"],
            r["model"].split(":", 1)[-1][:30],
            f"{r['overall_score']:.1f}",
            f"{r['avg_latency_ms']:.0f}",
            f"{r['p95_latency_ms']:.0f}",
            f"{(r['sentiment_accuracy'] or 0) * 100:.0f}%" if r["sentiment_accuracy"] is not None else "N/A",
            f"{r['avg_quality'] * 100:.0f}%",
            f"{r['estimated_cost_usd']:.4f}",
        ])
    widths = [len(h) for h in headers]
    for row in rows:
        for i, cell in enumerate(row):
            widths[i] = max(widths[i], len(str(cell)))
    line = "+-" + "-+-".join("-" * w for w in widths) + "-+"
    def fmt_row(cells):
        return "| " + " | ".join(str(c).ljust(widths[i]) for i, c in enumerate(cells)) + " |"
    print(line)
    print(fmt_row(headers))
    print(line)
    for r in rows:
        print(fmt_row(r))
    print(line)


def write_markdown_report(data: dict, out_path: Path) -> None:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    lines: list[str] = []
    lines.append(f"# LLM Evaluation Report — {data['timestamp']}")
    lines.append("")
    lines.append(f"- Prompts evaluated: **{data['prompts']}**")
    lines.append(f"- Recommended provider: **{data['recommendation']}**")
    lines.append("")
    lines.append("## Ranking")
    lines.append("")
    lines.append("| Rank | Provider | Model | Overall Score |")
    lines.append("|---|---|---|---|")
    for r in data["ranking"]:
        lines.append(f"| {r['rank']} | {r['provider']} | {r['model']} | {r['overall_score']:.2f} |")
    lines.append("")
    lines.append("## Per-model metrics")
    lines.append("")
    lines.append("| Provider | Model | Avg ms | P95 ms | Sent Acc | Avg Quality | Est Cost $ |")
    lines.append("|---|---|---|---|---|---|---|")
    for r in data["results"]:
        sa = f"{r['sentiment_accuracy']*100:.1f}%" if r["sentiment_accuracy"] is not None else "N/A"
        lines.append(
            f"| {r['provider']} | {r['model']} | {r['avg_latency_ms']:.0f} | "
            f"{r['p95_latency_ms']:.0f} | {sa} | {r['avg_quality']*100:.1f}% | {r['estimated_cost_usd']:.5f} |"
        )
    out_path.write_text("\n".join(lines), encoding="utf-8")
    print(f"\nMarkdown report: {out_path}")


def main() -> int:
    parser = argparse.ArgumentParser(description="AI Chat — LLM benchmark runner")
    parser.add_argument("--backend", default=BACKEND_URL, help="FastAPI backend URL")
    parser.add_argument("--no-judge", action="store_true", help="Use heuristic quality scoring only")
    parser.add_argument("--wait", type=int, default=0, help="Seconds to wait for backend readiness (0 = skip)")
    parser.add_argument("--save", type=Path, default=None, help="Folder to write {benchmark.json, benchmark.md} reports")
    args = parser.parse_args()

    global BACKEND_URL
    BACKEND_URL = args.backend.rstrip("/")

    if args.wait:
        print(f"Waiting up to {args.wait}s for backend at {BACKEND_URL} ...")
        if not wait_for_backend(args.wait):
            print(f"\nBackend not reachable at {BACKEND_URL}")
            return 2

    print(f"Running benchmark against {BACKEND_URL} ...")
    t0 = time.time()
    data = post_json("/benchmark", {"use_judge_llm": not args.no_judge}, timeout=900)
    elapsed = time.time() - t0
    print(f"Benchmark completed in {elapsed:.1f}s.\n")

    print_table(data["results"])
    print(f"\n🏆  Recommended provider: {data['recommendation']}")

    if args.save:
        args.save.mkdir(parents=True, exist_ok=True)
        ts = datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")
        json_path = args.save / f"benchmark-{ts}.json"
        md_path = args.save / f"benchmark-{ts}.md"
        json_path.write_text(json.dumps(data, indent=2), encoding="utf-8")
        write_markdown_report(data, md_path)
        print(f"JSON report:     {json_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
