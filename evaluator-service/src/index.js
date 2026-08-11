/**
 * AI Chat — Node.js LLM Evaluator Service
 * ----------------------------------------
 * Aligns with the role requirements:
 *   - Node.js (Express)
 *   - LLM evaluation / model optimisation
 *   - NLP (sentiment accuracy check, coherence scoring)
 *   - Hugging Face (calls the Python backend's /sentiment for reference)
 *
 * Endpoints:
 *   GET  /health                       -> service health
 *   POST /evaluate                     -> run a full evaluation job:
 *           {
 *             backends: [{label, baseUrl, apiKey?, model?}],
 *             prompts:  [{prompt, expectedSentiment?}],
 *             judgeProvider?: {type:"openai"|"openai_compat", ...}
 *           }
 *
 * It sends each prompt to every backend, records latency, token counts,
 * asks a judge LLM (or heuristic) for quality score, compares the
 * Python backend's /sentiment label to expectedSentiment for NLP accuracy,
 * and returns an aggregate score per backend + a ranked recommendation.
 */

import "dotenv/config";
import express from "express";
import cors from "cors";
import pino from "pino";
import OpenAI from "openai";

const logger = pino({ level: process.env.LOG_LEVEL ?? "info" });
const app = express();
app.use(cors());
app.use(express.json({ limit: "2mb" }));

const PORT = Number(process.env.PORT ?? 8787);
const PYTHON_BACKEND_URL =
  process.env.PYTHON_BACKEND_URL ?? "http://localhost:8000";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function fetchJson(url, options, timeoutMs = 60_000) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), timeoutMs);
  try {
    const res = await fetch(url, { ...options, signal: ctrl.signal });
    const text = await res.text();
    let body;
    try { body = JSON.parse(text); } catch { body = text; }
    return { status: res.status, ok: res.ok, body };
  } finally {
    clearTimeout(t);
  }
}

async function measure(fn) {
  const t0 = performance.now();
  const result = await fn();
  return { result, latencyMs: Math.round(performance.now() - t0) };
}

// Tiny token counter (approximation ~ GPT tokenizer / 4 chars)
function countTokens(text) {
  if (!text) return 0;
  return Math.max(1, Math.ceil(text.length / 4));
}

// Heuristic quality scorer used when no judge LLM is configured.
// Rewards: length within window, no repeats, answers the prompt keywords.
function heuristicQuality(prompt, reply) {
  if (!reply) return 0;
  const r = reply.toLowerCase();
  const p = prompt.toLowerCase();
  const promptTokens = p.split(/\s+/).filter(Boolean);
  const overlap = promptTokens.filter((w) => w.length >= 4 && r.includes(w)).length;
  const overlapScore = Math.min(1, overlap / Math.max(1, promptTokens.length * 0.25));
  const len = reply.length;
  const lengthScore =
    len < 30 ? len / 30 :
    len < 600 ? 1 :
    Math.max(0, 1 - (len - 600) / 1500);
  // Penalise obvious repetitions
  const words = r.split(/\s+/);
  const unique = new Set(words).size;
  const repeatPenalty = unique / Math.max(1, words.length);
  const score = 0.4 * overlapScore + 0.4 * lengthScore + 0.2 * repeatPenalty;
  return Math.round(score * 100) / 100;
}

async function judgeQuality(prompt, reply, judgeCfg) {
  if (!judgeCfg) return { score: heuristicQuality(prompt, reply), judgedBy: "heuristic" };
  try {
    const client = new OpenAI({
      baseURL: judgeCfg.baseUrl,
      apiKey: judgeCfg.apiKey ?? "dummy",
    });
    const system =
      "You are an LLM evaluation judge. Rate the assistant reply quality on a scale from 0.00 to 1.00. " +
      "Consider helpfulness, correctness, coherence, and conciseness. " +
      "Return a single JSON object with the shape {\"score\": number, \"rationale\": string}. No prose.";
    const user =
      `PROMPT:\n${prompt}\n\nREPLY:\n${reply ?? ""}`;
    const out = await client.chat.completions.create({
      model: judgeCfg.model ?? "gpt-4o-mini",
      messages: [
        { role: "system", content: system },
        { role: "user", content: user },
      ],
      temperature: 0.1,
      response_format: { type: "json_object" },
      max_tokens: 256,
    });
    const parsed = JSON.parse(out.choices[0].message.content ?? "{}");
    const score = Math.max(0, Math.min(1, Number(parsed.score ?? 0)));
    return { score: Math.round(score * 100) / 100, judgedBy: judgeCfg.model ?? "judge-llm", rationale: parsed.rationale };
  } catch (err) {
    logger.warn({ err }, "Judge LLM call failed; falling back to heuristic");
    return { score: heuristicQuality(prompt, reply), judgedBy: "heuristic" };
  }
}

// Calls the Python backend's /sentiment endpoint for the reply
// so we can validate NLP behaviour end-to-end.
async function sentimentFromPython(text) {
  try {
    const { ok, body } = await fetchJson(`${PYTHON_BACKEND_URL}/sentiment`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ message: text }),
    });
    if (!ok) return null;
    return { label: body.label, confidence: Number(body.confidence ?? 0) };
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Core evaluator
// ---------------------------------------------------------------------------
async function callBackend(backend, prompt) {
  const url = `${backend.baseUrl.replace(/\/$/, "")}/chat`;
  const headers = { "Content-Type": "application/json" };
  if (backend.apiKey) headers["Authorization"] = `Bearer ${backend.apiKey}`;
  const { result, latencyMs } = await measure(async () =>
    fetchJson(url, {
      method: "POST",
      headers,
      body: JSON.stringify({
        message: prompt,
        session_id: null,
      }),
    }),
  );
  if (!result.ok) {
    return { error: `HTTP ${result.status}`, latencyMs };
  }
  const reply = result.body.reply ?? "";
  const sentiment = result.body.sentiment ?? null;
  const provider = result.body.provider ?? null;
  const model = result.body.model ?? null;
  return {
    reply,
    sentiment,
    provider,
    model,
    outputTokens: countTokens(reply),
    inputTokens: countTokens(prompt),
    latencyMs,
  };
}

async function runEvaluation(job) {
  const {
    backends = [],
    prompts = [],
    judgeProvider = null,
    costPer1kInputTokens = {},   // { [backendLabel]: $amount }
    costPer1kOutputTokens = {},
  } = job;

  const perBackend = {};
  for (const b of backends) perBackend[b.label] = {
    label: b.label,
    runs: [],
    totalLatencyMs: 0,
    avgLatencyMs: 0,
    p95LatencyMs: 0,
    totalInputTokens: 0,
    totalOutputTokens: 0,
    estCostUsd: 0,
    sentimentAccuracy: null,
    qualityScores: [],
    avgQuality: 0,
    errors: 0,
    overallScore: 0,
    notes: [],
  };

  const nExpected = Math.max(1, prompts.length);

  for (const backend of backends) {
    const acc = perBackend[backend.label];
    const latencies = [];
    const sentimentMatches = [];
    for (const item of prompts) {
      const prompt = typeof item === "string" ? item : item.prompt;
      const expectedSentiment = typeof item === "string" ? null : item.expectedSentiment ?? null;
      const res = await callBackend(backend, prompt);
      if (res.error) {
        acc.errors += 1;
        acc.notes.push(`Prompt "${prompt.slice(0, 40)}…" failed: ${res.error}`);
        continue;
      }
      // NLP check: cross-check python-reported sentiment vs expected label
      const pythonSentiment =
        expectedSentiment ? await sentimentFromPython(prompt) : null;
      if (expectedSentiment && pythonSentiment) {
        const match = expectedSentiment.toLowerCase() === pythonSentiment.label.toLowerCase();
        sentimentMatches.push(match ? 1 : 0);
      }
      const quality = await judgeQuality(prompt, res.reply, judgeProvider);
      acc.qualityScores.push(quality.score);
      acc.runs.push({
        prompt: prompt.slice(0, 200),
        reply: res.reply.slice(0, 500),
        latencyMs: res.latencyMs,
        inputTokens: res.inputTokens,
        outputTokens: res.outputTokens,
        sentiment: res.sentiment,
        pythonSentiment,
        expectedSentiment,
        quality,
      });
      latencies.push(res.latencyMs);
      acc.totalLatencyMs += res.latencyMs;
      acc.totalInputTokens += res.inputTokens;
      acc.totalOutputTokens += res.outputTokens;
    }

    latencies.sort((a, b) => a - b);
    acc.avgLatencyMs = latencies.length
      ? Math.round(acc.totalLatencyMs / latencies.length)
      : 0;
    acc.p95LatencyMs = latencies.length
      ? latencies[Math.ceil(0.95 * latencies.length) - 1] ?? 0
      : 0;
    acc.sentimentAccuracy = sentimentMatches.length
      ? Math.round((sentimentMatches.reduce((a, b) => a + b, 0) / sentimentMatches.length) * 10000) / 10000
      : null;
    acc.avgQuality = acc.qualityScores.length
      ? Math.round((acc.qualityScores.reduce((a, b) => a + b, 0) / acc.qualityScores.length) * 10000) / 10000
      : 0;

    const ci = Number(costPer1kInputTokens[backend.label] ?? 0) / 1000;
    const co = Number(costPer1kOutputTokens[backend.label] ?? 0) / 1000;
    acc.estCostUsd = Math.round(
      (acc.totalInputTokens * ci + acc.totalOutputTokens * co) * 1e6,
    ) / 1e6;

    // Overall score (0–100): 40% quality, 25% latency (lower better),
    // 20% sentiment accuracy, 15% cost (lower better). Penalise errors.
    const completedRuns = acc.runs.length;
    const errorPenalty = 1 - acc.errors / nExpected;
    const qScore = (acc.avgQuality ?? 0) * 40;
    const latScore = acc.p95LatencyMs
      ? Math.max(0, 25 - Math.min(25, (acc.p95LatencyMs / 10_000) * 25))
      : 0;
    const nlpScore = (acc.sentimentAccuracy ?? 0) * 20;
    const costScore = acc.estCostUsd
      ? Math.max(0, 15 - Math.min(15, (acc.estCostUsd / 0.5) * 15))
      : 15;
    acc.overallScore = Math.round(
      (qScore + latScore + nlpScore + costScore) * errorPenalty * 100,
    ) / 100;
  }

  const ranking = Object.values(perBackend)
    .sort((a, b) => b.overallScore - a.overallScore)
    .map((x, i) => ({ rank: i + 1, label: x.label, overallScore: x.overallScore }));

  return {
    timestamp: new Date().toISOString(),
    pythonBackend: PYTHON_BACKEND_URL,
    promptsEvaluated: prompts.length,
    backendsEvaluated: backends.length,
    perBackend,
    ranking,
    recommendation: ranking[0]?.label ?? null,
  };
}

// ---------------------------------------------------------------------------
// Routes
// ---------------------------------------------------------------------------
app.get("/health", (_req, res) => {
  res.json({
    status: "llm-evaluator running",
    nodeVersion: process.version,
    pythonBackend: PYTHON_BACKEND_URL,
  });
});

app.post("/evaluate", async (req, res) => {
  try {
    const result = await runEvaluation(req.body ?? {});
    res.json(result);
  } catch (err) {
    logger.error({ err }, "Evaluation job failed");
    res.status(500).json({ error: String(err?.message ?? err) });
  }
});

app.listen(PORT, () => {
  logger.info(
    { port: PORT, pythonBackend: PYTHON_BACKEND_URL },
    "LLM Evaluator service listening",
  );
});
