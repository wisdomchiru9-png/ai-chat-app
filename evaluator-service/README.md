# AI Chat — LLM Evaluator Service (Node.js / Express)

This service adds the **Node.js** + **LLM evaluation** + **NLP** bullets to the role
resume match. It runs reproducible benchmarks across any number of backends, scores each
model on latency, quality (judge-LLM or heuristic), sentiment-analysis accuracy
(by calling the Python backend's `/sentiment`), and estimated cost.

## Run

```bash
cd evaluator-service
cp .env.example .env          # optional
npm install
npm run dev                   # or: npm start
```

Listens on `http://localhost:8787` by default.

## Example — evaluate 2 backends with a judge LLM

```bash
curl -X POST http://localhost:8787/evaluate \
  -H 'content-type: application/json' \
  -d '{
    "backends": [
      {"label": "local-dev",   "baseUrl": "http://localhost:8000"},
      {"label": "staging-gpu", "baseUrl": "https://staging.example.com"}
    ],
    "prompts": [
      {"prompt": "Give me 3 tips to improve my resume.", "expectedSentiment": "POSITIVE"},
      {"prompt": "My app keeps crashing on startup, what should I try?", "expectedSentiment": "NEGATIVE"}
    ],
    "judgeProvider": {
      "type": "openai",
      "baseUrl": "https://api.openai.com/v1",
      "apiKey": "sk-proj-...",
      "model": "gpt-4o-mini"
    },
    "costPer1kInputTokens":  {"local-dev": 0, "staging-gpu": 0.3},
    "costPer1kOutputTokens": {"local-dev": 0, "staging-gpu": 0.9}
  }'
```

Returns per-backend `avgLatencyMs`, `p95LatencyMs`, `sentimentAccuracy`,
`avgQuality`, `estCostUsd`, an `overallScore` (0-100), and a ranked
`recommendation` for which backend to use.
