"""
AI Chat Backend — FastAPI + Plugable LLMs + PostgreSQL chat history
--------------------------------------------------------------------
Flutter (chat UI) → HTTP → FastAPI → LLM → response back
                         ↘ SQLAlchemy → SQLite / PostgreSQL

Endpoints:
  Health / meta:
    GET  /                              -> health check, provider + DB info
  Sentiment / chat:
    POST /sentiment                     -> sentiment only
    POST /chat                          -> chat + persist (optional session_id)
  Sessions REST:
    POST   /sessions                    -> create session (returns id)
    GET    /sessions                    -> list all sessions (most recent first)
    GET    /sessions/{id}               -> session summary + messages
    GET    /sessions/{id}/messages      -> session messages only
    PATCH  /sessions/{id}               -> rename session title
    DELETE /sessions/{id}               -> delete session + its messages

LLM providers (choose via .env LLM_PROVIDER):
  openai         - OpenAI Chat Completions API
  openai_compat  - Any OpenAI-compatible endpoint (Together, Groq, Ollama /v1…)
  hf_inference   - Hugging Face Inference API (Zephyr-7B)
  local          - Local transformers or rule-based fallback

Database (DATABASE_URL in .env):
  sqlite:///./ai_chat_app.db   (default, zero-setup local file)
  postgresql+psycopg://user:pass@host:5432/dbname

Run:
    python -m pip install -r requirements.txt
    copy .env.example .env
    uvicorn main:app --reload --host 0.0.0.0 --port 8000
Docs: http://localhost:8000/docs
"""

import os
import logging
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional, Union, Iterator

try:
    from dotenv import load_dotenv
    load_dotenv(Path(__file__).with_name(".env"))
except Exception:
    pass

from fastapi import FastAPI, HTTPException, Depends, Query
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field, ConfigDict

# ---------------------------------------------------------------------------
# Logging & app
# ---------------------------------------------------------------------------
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger(__name__)

app = FastAPI(
    title="AI Chat Backend",
    description="FastAPI backend for AI Chat. Plugable LLM, sentiment, multi-turn history, PostgreSQL persistence.",
    version="3.0.0",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# ---------------------------------------------------------------------------
# Config from env
# ---------------------------------------------------------------------------
LLM_PROVIDER = os.getenv("LLM_PROVIDER", "local").strip().lower()
LLM_TEMPERATURE = float(os.getenv("LLM_TEMPERATURE", "0.7"))
LLM_MAX_TOKENS = int(os.getenv("LLM_MAX_TOKENS", "300"))
LLM_SYSTEM_PROMPT = os.getenv(
    "LLM_SYSTEM_PROMPT",
    "You are a friendly, concise AI assistant. Acknowledge the user's mood naturally. Keep replies under ~300 tokens.",
).strip()
DATABASE_URL = os.getenv(
    "DATABASE_URL",
    f"sqlite:///{Path(__file__).parent / 'ai_chat_app.db'}",
).strip()

VALID_PROVIDERS = {"openai", "openai_compat", "hf_inference", "local"}
if LLM_PROVIDER not in VALID_PROVIDERS:
    logger.warning(f"Unknown LLM_PROVIDER='{LLM_PROVIDER}' — falling back to 'local'")
    LLM_PROVIDER = "local"


# ---------------------------------------------------------------------------
# Database — SQLAlchemy 2.0 (SQLite by default, Postgres via DATABASE_URL)
# ---------------------------------------------------------------------------
from sqlalchemy import (
    create_engine,
    ForeignKey,
    String,
    Text,
    DateTime,
    Float,
    Integer,
    func,
)
from sqlalchemy.orm import (
    DeclarativeBase,
    Mapped,
    mapped_column,
    relationship,
    sessionmaker,
    Session as SASession,
)

_DB_KWARGS = {}
if DATABASE_URL.startswith("sqlite"):
    _DB_KWARGS["connect_args"] = {"check_same_thread": False}

engine = create_engine(DATABASE_URL, future=True, **_DB_KWARGS)
SessionLocal = sessionmaker(bind=engine, autoflush=False, autocommit=False, future=True)


class Base(DeclarativeBase):
    pass


def utcnow() -> datetime:
    return datetime.now(timezone.utc).replace(tzinfo=None)


class User(Base):
    __tablename__ = "users"
    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    external_id: Mapped[str] = mapped_column(String(64), unique=True, index=True,
                                              default=lambda: f"user_{uuid.uuid4().hex[:12]}")
    display_name: Mapped[str] = mapped_column(String(120), default="User")
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow, index=True)
    sessions: Mapped[list["ChatSession"]] = relationship(back_populates="user",
                                                          cascade="all, delete-orphan")


class ChatSession(Base):
    __tablename__ = "chat_sessions"
    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    session_id: Mapped[str] = mapped_column(String(32), unique=True, index=True,
                                             default=lambda: uuid.uuid4().hex)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    title: Mapped[str] = mapped_column(String(160), default="New chat")
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow, index=True)
    updated_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow, onupdate=utcnow, index=True)

    user: Mapped["User"] = relationship(back_populates="sessions")
    messages: Mapped[list["ChatMessageDB"]] = relationship(
        back_populates="session",
        cascade="all, delete-orphan",
        order_by="ChatMessageDB.created_at.asc()",
    )


class ChatMessageDB(Base):
    __tablename__ = "chat_messages"
    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    session_id: Mapped[int] = mapped_column(ForeignKey("chat_sessions.id", ondelete="CASCADE"), index=True)
    role: Mapped[str] = mapped_column(String(16), index=True)  # "user" | "assistant"
    content: Mapped[str] = mapped_column(Text, default="")
    sentiment_label: Mapped[Optional[str]] = mapped_column(String(16), nullable=True)
    sentiment_confidence: Mapped[Optional[float]] = mapped_column(Float, nullable=True)
    llm_provider: Mapped[Optional[str]] = mapped_column(String(32), nullable=True)
    llm_model: Mapped[Optional[str]] = mapped_column(String(120), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow, index=True)

    session: Mapped["ChatSession"] = relationship(back_populates="messages")


def get_db() -> Iterator[SASession]:
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


def _get_or_create_default_user(db: SASession) -> User:
    """For a portfolio / single-user app, use one default user id."""
    external_id = "default_user"
    user = db.query(User).filter(User.external_id == external_id).one_or_none()
    if user is None:
        user = User(external_id=external_id, display_name="You")
        db.add(user)
        db.commit()
        db.refresh(user)
    return user


# ---------------------------------------------------------------------------
# Sentiment analysis (shared regardless of LLM provider)
# ---------------------------------------------------------------------------
_HF_TOKEN = os.getenv("HUGGINGFACE_TOKEN") or ""

_sentiment_remote = None
_sentiment_local = None

if _HF_TOKEN:
    try:
        from huggingface_hub import InferenceClient
        _sentiment_remote = InferenceClient(
            model="distilbert/distilbert-base-uncased-finetuned-sst-2-english",
            token=_HF_TOKEN,
        )
        logger.info("Sentiment: Hugging Face Inference API (remote distilbert)")
    except Exception as e:
        logger.warning(f"Failed to init remote sentiment, will try local: {e}")

if _sentiment_remote is None:
    try:
        from transformers import pipeline
        _sentiment_local = pipeline(
            "sentiment-analysis",
            model="distilbert/distilbert-base-uncased-finetuned-sst-2-english",
        )
        logger.info("Sentiment: Local transformers (distilbert)")
    except Exception as e:
        logger.warning(f"Sentiment: local transformers unavailable ({e}); using keyword fallback")


def _classify_sentiment_remote(text: str) -> tuple[str, float]:
    res = _sentiment_remote.text_classification(text)
    top = max(res, key=lambda x: x.score)
    return str(top.label), round(float(top.score), 3)


def _classify_sentiment_local(text: str) -> tuple[str, float]:
    r = _sentiment_local(text, truncation=True, max_length=512)[0]
    return r["label"], round(float(r["score"]), 3)


_POS_KEYWORDS = ("love", "great", "awesome", "amazing", "happy", "excellent", "good", "thanks", "thank", "perfect")
_NEG_KEYWORDS = ("hate", "terrible", "awful", "sad", "angry", "bad", "worst", "stuck", "frustrated", "annoyed", "suck")


def _classify_sentiment_fallback(text: str) -> tuple[str, float]:
    t = text.lower()
    pos = sum(k in t for k in _POS_KEYWORDS)
    neg = sum(k in t for k in _NEG_KEYWORDS)
    if pos > neg:
        return "POSITIVE", min(0.95, 0.55 + 0.08 * pos)
    if neg > pos:
        return "NEGATIVE", min(0.95, 0.55 + 0.08 * neg)
    return "POSITIVE" if t.endswith(("!", "?", ".", ";")) else "NEGATIVE", 0.51


def classify_sentiment(text: str) -> tuple[str, float]:
    try:
        if _sentiment_remote is not None:
            return _classify_sentiment_remote(text)
        if _sentiment_local is not None:
            return _classify_sentiment_local(text)
    except Exception as e:
        logger.warning(f"Sentiment classifier threw, using keyword fallback: {e}")
    return _classify_sentiment_fallback(text)


# ---------------------------------------------------------------------------
# LLM adapters
# ---------------------------------------------------------------------------
class BaseLLM:
    name: str = "base"

    def __init__(self):
        self.available = False
        self.model_label = "(unknown)"
        self._post_init()

    def _post_init(self):
        raise NotImplementedError

    def generate(self, messages: list[dict]) -> str:
        raise NotImplementedError


class OpenAILLM(BaseLLM):
    name = "openai"

    def _post_init(self):
        self.api_key = os.getenv("OPENAI_API_KEY", "").strip()
        self.model = os.getenv("OPENAI_MODEL", "gpt-4o-mini").strip()
        self.model_label = f"{self.name}:{self.model}"
        if not self.api_key:
            logger.warning("OpenAI: OPENAI_API_KEY not set — provider unavailable")
            return
        try:
            from openai import OpenAI
            self.client = OpenAI(api_key=self.api_key)
            self.available = True
            logger.info(f"LLM: OpenAI (model={self.model})")
        except Exception as e:
            logger.warning(f"OpenAI client init failed: {e}")

    def generate(self, messages: list[dict]) -> str:
        resp = self.client.chat.completions.create(
            model=self.model,
            messages=messages,
            temperature=LLM_TEMPERATURE,
            max_tokens=LLM_MAX_TOKENS,
        )
        return (resp.choices[0].message.content or "").strip()


class OpenAICompatLLM(BaseLLM):
    name = "openai_compat"

    def _post_init(self):
        self.base_url = os.getenv("OPENAI_COMPAT_BASE_URL", "").strip()
        self.api_key = os.getenv("OPENAI_COMPAT_API_KEY", "").strip() or "dummy"
        self.model = os.getenv("OPENAI_COMPAT_MODEL", "").strip()
        self.model_label = f"{self.name}:{self.model or '(no model)'}"
        if not self.base_url or not self.model:
            logger.warning("OpenAI-compat: missing env — provider unavailable")
            return
        try:
            from openai import OpenAI
            self.client = OpenAI(base_url=self.base_url, api_key=self.api_key)
            self.available = True
            logger.info(f"LLM: OpenAI-compatible (base={self.base_url}, model={self.model})")
        except Exception as e:
            logger.warning(f"OpenAI-compat client init failed: {e}")

    def generate(self, messages: list[dict]) -> str:
        resp = self.client.chat.completions.create(
            model=self.model,
            messages=messages,
            temperature=LLM_TEMPERATURE,
            max_tokens=LLM_MAX_TOKENS,
        )
        return (resp.choices[0].message.content or "").strip()


class HFInferenceLLM(BaseLLM):
    name = "hf_inference"

    def _post_init(self):
        self.model = "HuggingFaceH4/zephyr-7b-beta"
        self.model_label = f"{self.name}:{self.model}"
        if not _HF_TOKEN:
            logger.warning("HF Inference: HUGGINGFACE_TOKEN not set — provider unavailable")
            return
        try:
            from huggingface_hub import InferenceClient
            self.client = InferenceClient(model=self.model, token=_HF_TOKEN)
            self.available = True
            logger.info(f"LLM: Hugging Face Inference API (model={self.model})")
        except Exception as e:
            logger.warning(f"HF Inference init failed: {e}")

    @staticmethod
    def _to_chatml(messages: list[dict]) -> str:
        out = []
        for m in messages:
            role, content = m.get("role", "user"), m.get("content", "")
            out.append(f"<|{role}|>\n{content}\n")
        out.append("<|assistant|>\n")
        return "".join(out)

    def generate(self, messages: list[dict]) -> str:
        prompt = self._to_chatml(messages)
        out = self.client.text_generation(
            prompt,
            max_new_tokens=LLM_MAX_TOKENS,
            temperature=LLM_TEMPERATURE,
            top_p=0.92,
            do_sample=True,
            stop_sequences=["</s>", "<|user|>", "<|system|>"],
        )
        text = str(out).strip()
        for stop in ("<|user|>", "<|system|>", "</s>", "\n\nUser:"):
            if stop in text:
                text = text.split(stop)[0]
        return text.strip()


class LocalLLM(BaseLLM):
    name = "local"

    def _post_init(self):
        self._pipe = None
        self.model_label = "local:rule-based"
        try:
            from transformers import pipeline
            self._pipe = pipeline(
                "text-generation",
                model="distilgpt2",
                max_new_tokens=min(LLM_MAX_TOKENS, 200),
                temperature=LLM_TEMPERATURE,
                top_p=0.9,
                do_sample=True,
                pad_token_id=50256,
            )
            self.model_label = "local:distilgpt2"
            logger.info("LLM: Local transformers (distilgpt2)")
        except Exception as e:
            logger.warning(f"LLM: local transformers not available ({e}); using rule-based")
        self.available = True

    @staticmethod
    def _to_simple_prompt(messages: list[dict]) -> str:
        lines = []
        for m in messages:
            role, content = m.get("role", "user"), m.get("content", "")
            if role == "system":
                lines.append(content)
            elif role == "user":
                lines.append(f"User: {content}")
            else:
                lines.append(f"Assistant: {content}")
        lines.append("Assistant:")
        return "\n".join(lines)

    @staticmethod
    def _rule_based(messages: list[dict], label: str) -> str:
        user_last = ""
        for m in reversed(messages):
            if m.get("role") == "user":
                user_last = m.get("content", "")
                break
        m = user_last.lower().strip()
        if any(g in m for g in ("hello", "hi", "hey", "yo", "greetings", "hola")):
            return "Hi there! I'm your AI assistant. How can I help you today?"
        if any(q in m for q in ("how are you", "how's it going", "how do you do")):
            return "I'm doing great, thanks for asking! I'm here and ready to chat."
        if any(b in m for b in ("bye", "goodbye", "see you", "cya", "later")):
            return "Goodbye! Have a wonderful day and come back anytime."
        if any(t in m for t in ("thank", "thanks", "appreciate")):
            return "You're very welcome!"
        if any(q in m for q in ("your name", "who are you", "what are you")):
            return "I'm your AI assistant, powered by whichever LLM you've configured in the backend."
        if label == "POSITIVE":
            return f"That's wonderful to hear! About \"{user_last[:80]}\" — tell me more."
        return f"I understand. About \"{user_last[:80]}\" — I'm here to listen. Want to share more?"

    def generate(self, messages: list[dict], *, sentiment_label: str = "POSITIVE") -> str:
        if self._pipe is not None:
            try:
                prompt = self._to_simple_prompt(messages)
                out = self._pipe(prompt)
                full = out[0]["generated_text"]
                reply = full[len(prompt):].strip()
                for stop in ("\n\n", "\nUser:", "\nAssistant:"):
                    if stop in reply:
                        reply = reply.split(stop)[0]
                reply = reply.strip()
                if reply:
                    return reply
            except Exception as e:
                logger.warning(f"Local distilgpt2 failed, falling back to rule-based: {e}")
        return self._rule_based(messages, sentiment_label)


# ---------------------------------------------------------------------------
# Provider auto-selection with fallbacks
# ---------------------------------------------------------------------------
_PROVIDER_MAP: dict[str, type[BaseLLM]] = {
    "openai": OpenAILLM,
    "openai_compat": OpenAICompatLLM,
    "hf_inference": HFInferenceLLM,
    "local": LocalLLM,
}

_FALLBACK_ORDER = ["openai", "openai_compat", "hf_inference", "local"]

_instantiated_llms: dict[str, BaseLLM] = {}
_active_llm: Optional[BaseLLM] = None


def _init_llms() -> BaseLLM:
    global _active_llm
    for key in _FALLBACK_ORDER:
        if key not in _instantiated_llms:
            try:
                _instantiated_llms[key] = _PROVIDER_MAP[key]()
            except Exception as e:
                logger.error(f"Failed to instantiate LLM '{key}': {e}")
                continue
    req = _instantiated_llms.get(LLM_PROVIDER)
    if req and req.available:
        _active_llm = req
        return req
    for key in _FALLBACK_ORDER:
        cand = _instantiated_llms.get(key)
        if cand and cand.available:
            logger.warning(f"Requested LLM provider '{LLM_PROVIDER}' unavailable — falling back to '{key}'")
            _active_llm = cand
            return cand
    ultimate = LocalLLM()
    _active_llm = ultimate
    return ultimate


_llm_instance: BaseLLM = _init_llms()


def active_llm() -> BaseLLM:
    return _llm_instance


# ---------------------------------------------------------------------------
# Request / Response models
# ---------------------------------------------------------------------------
class HistoryMessage(BaseModel):
    role: str = Field(..., pattern=r"^(system|user|assistant)$")
    content: str = Field(..., min_length=0, max_length=4000)


class ChatRequest(BaseModel):
    message: str = Field(..., min_length=1, max_length=2000, description="Latest user message")
    history: Optional[list[Union[dict, HistoryMessage]]] = Field(
        default=None,
        description="Conversation history (earliest first). If omitted but session_id is provided, history is loaded from DB.",
    )
    session_id: Optional[str] = Field(
        default=None,
        description="Optional session id (from POST /sessions). When provided, turn is persisted to DB.",
    )


class SentimentResponse(BaseModel):
    label: str
    confidence: float


class ChatResponse(BaseModel):
    reply: str
    sentiment: str
    confidence: float
    provider: str
    model: str
    session_id: Optional[str] = None


# Session DTOs
class SessionCreate(BaseModel):
    title: Optional[str] = Field(default=None, max_length=160)


class SessionUpdate(BaseModel):
    title: str = Field(..., min_length=1, max_length=160)


class SessionOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    session_id: str
    title: str
    created_at: datetime
    updated_at: datetime
    message_count: int = 0


class SessionDetail(SessionOut):
    messages: list[dict] = []


class MessageOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: int
    role: str
    content: str
    sentiment_label: Optional[str] = None
    sentiment_confidence: Optional[float] = None
    llm_provider: Optional[str] = None
    llm_model: Optional[str] = None
    created_at: datetime


# ---------------------------------------------------------------------------
# Helpers: history normalisation + window trim
# ---------------------------------------------------------------------------
def _normalise_history(raw: Optional[list[Union[dict, HistoryMessage]]]) -> list[dict]:
    if not raw:
        return []
    norm = []
    for m in raw:
        if isinstance(m, HistoryMessage):
            norm.append({"role": m.role, "content": m.content})
        elif isinstance(m, dict):
            role = str(m.get("role", "user")).lower()
            content = str(m.get("content", ""))
            if role in ("system", "user", "assistant"):
                norm.append({"role": role, "content": content})
    merged = []
    for m in norm:
        if merged and merged[-1]["role"] == m["role"]:
            merged[-1]["content"] = (merged[-1]["content"] + "\n" + m["content"]).strip()
        else:
            merged.append(m)
    return merged


def _trim_to_context_window(
    history: list[dict],
    max_chars: int = 8000,
    keep_system: bool = True,
) -> list[dict]:
    if not history:
        return history
    system = None
    rest = history
    if keep_system and history[0]["role"] == "system":
        system = history[0]
        rest = history[1:]
    tail: list[dict] = []
    total = 0
    for m in reversed(rest):
        size = len(m["content"]) + 8
        if total + size > max_chars and tail:
            break
        tail.append(m)
        total += size
    tail.reverse()
    return ([system] + tail) if system else tail


def build_messages_for_llm(request: ChatRequest, db_history: list[dict] | None = None) -> list[dict]:
    """Priority: explicit request.history > session history loaded from DB > empty."""
    if request.history is not None:
        norm = _normalise_history(request.history)
    elif db_history is not None:
        norm = list(db_history)
    else:
        norm = []
    trimmed = _trim_to_context_window(norm)
    if not trimmed or trimmed[0]["role"] != "system":
        trimmed = [{"role": "system", "content": LLM_SYSTEM_PROMPT}] + trimmed
    latest = {"role": "user", "content": request.message}
    if not (trimmed and trimmed[-1]["role"] == "user" and trimmed[-1]["content"] == request.message):
        trimmed.append(latest)
    return _trim_to_context_window(trimmed)


# ---------------------------------------------------------------------------
# Reply generator
# ---------------------------------------------------------------------------
def generate_reply_with_history(messages: list[dict], sentiment_label: str) -> tuple[str, str, str]:
    llm = active_llm()
    try:
        if isinstance(llm, LocalLLM):
            reply = llm.generate(messages, sentiment_label=sentiment_label)
        else:
            reply = llm.generate(messages)
        if not reply:
            raise RuntimeError("Empty reply from LLM")
        return reply, llm.name, llm.model_label
    except Exception as e:
        logger.warning(f"LLM '{llm.name}' failed ({e}); trying fallback providers in-process")
        for key in _FALLBACK_ORDER:
            cand = _instantiated_llms.get(key)
            if not cand or not cand.available or cand is llm:
                continue
            try:
                if isinstance(cand, LocalLLM):
                    reply = cand.generate(messages, sentiment_label=sentiment_label)
                else:
                    reply = cand.generate(messages)
                if reply:
                    logger.info(f"Fallback LLM '{key}' produced a reply")
                    return reply, cand.name, cand.model_label
            except Exception as e2:
                logger.warning(f"Fallback LLM '{key}' also failed: {e2}")
        lb = LocalLLM()
        return lb.generate(messages, sentiment_label=sentiment_label), lb.name, lb.model_label


# ---------------------------------------------------------------------------
# DB helpers for chat persistence
# ---------------------------------------------------------------------------
def _resolve_session(db: SASession, session_id: Optional[str]) -> Optional[ChatSession]:
    user = _get_or_create_default_user(db)
    if session_id is None or session_id == "":
        return None
    sess = db.query(ChatSession).filter(
        ChatSession.session_id == session_id,
        ChatSession.user_id == user.id,
    ).one_or_none()
    if sess is None:
        raise HTTPException(status_code=404, detail=f"Session '{session_id}' not found")
    return sess


def _session_to_dto(s: ChatSession) -> SessionOut:
    return SessionOut(
        session_id=s.session_id,
        title=s.title,
        created_at=s.created_at,
        updated_at=s.updated_at,
        message_count=len(s.messages),
    )


def _message_to_dict(m: ChatMessageDB) -> dict:
    return {
        "role": m.role,
        "content": m.content,
        "sentiment_label": m.sentiment_label,
        "sentiment_confidence": m.sentiment_confidence,
        "llm_provider": m.llm_provider,
        "llm_model": m.llm_model,
        "created_at": m.created_at.isoformat(),
    }


# ---------------------------------------------------------------------------
# Startup: create DB tables
# ---------------------------------------------------------------------------
@app.on_event("startup")
def _startup() -> None:
    logger.info(f"Using database: {DATABASE_URL.split('://')[0]}://***")
    Base.metadata.create_all(bind=engine)
    # Ensure default user exists
    with SessionLocal() as db:
        _get_or_create_default_user(db)


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------
@app.get("/")
def root(db: SASession = Depends(get_db)):
    llm = active_llm()
    user = _get_or_create_default_user(db)
    session_count = (
        db.query(func.count(ChatSession.id))
        .filter(ChatSession.user_id == user.id)
        .scalar()
        or 0
    )
    message_count = (
        db.query(func.count(ChatMessageDB.id))
        .join(ChatSession, ChatSession.id == ChatMessageDB.session_id)
        .filter(ChatSession.user_id == user.id)
        .scalar()
        or 0
    )
    return {
        "status": "AI Chat Backend is running",
        "llm": {
            "provider": llm.name,
            "model": llm.model_label,
            "configured_provider": LLM_PROVIDER,
        },
        "sentiment": {
            "remote": _sentiment_remote is not None,
            "local": _sentiment_local is not None,
            "fallback_keywords": _sentiment_remote is None and _sentiment_local is None,
        },
        "database": {
            "url_scheme": DATABASE_URL.split("://")[0],
            "sessions": session_count,
            "messages": message_count,
        },
        "docs": "/docs",
    }


@app.post("/sentiment", response_model=SentimentResponse)
def analyze_sentiment(request: ChatRequest):
    try:
        label, confidence = classify_sentiment(request.message)
        return SentimentResponse(label=label, confidence=confidence)
    except HTTPException:
        raise
    except Exception as e:
        logger.exception("Sentiment analysis failed")
        raise HTTPException(status_code=500, detail=f"Sentiment analysis failed: {e}")


@app.post("/chat", response_model=ChatResponse)
def chat(request: ChatRequest, db: SASession = Depends(get_db)):
    """
    1. Classifies sentiment on the latest user message
    2. Builds LLM history (explicit request.history > session history from DB > empty)
    3. Generates a reply via the active LLM (with provider fallback)
    4. If session_id is provided, persists the user+assistant turns to the DB
    """
    try:
        # --- Session / persistence prep
        session = _resolve_session(db, request.session_id)
        db_history: list[dict] | None = None
        if session is not None and request.history is None:
            db_history = [
                {"role": m.role, "content": m.content}
                for m in session.messages
            ]

        # --- Sentiment + LLM reply
        label, confidence = classify_sentiment(request.message)
        llm_messages = build_messages_for_llm(request, db_history=db_history)
        reply, provider_name, model_label = generate_reply_with_history(llm_messages, label)

        # --- Persist
        out_session_id: Optional[str] = None
        if session is not None:
            user_msg = ChatMessageDB(
                session_id=session.id,
                role="user",
                content=request.message,
            )
            ai_msg = ChatMessageDB(
                session_id=session.id,
                role="assistant",
                content=reply,
                sentiment_label=label,
                sentiment_confidence=confidence,
                llm_provider=provider_name,
                llm_model=model_label,
            )
            db.add_all([user_msg, ai_msg])
            # Auto-title first turn from the user message
            if (len(session.messages) == 0) and (session.title == "New chat"):
                session.title = request.message[:80].strip() or "New chat"
            session.updated_at = utcnow()
            db.commit()
            out_session_id = session.session_id

        return ChatResponse(
            reply=reply,
            sentiment=label,
            confidence=confidence,
            provider=provider_name,
            model=model_label,
            session_id=out_session_id,
        )
    except HTTPException:
        raise
    except Exception as e:
        logger.exception("Chat endpoint failed")
        raise HTTPException(status_code=500, detail=f"Chat error: {e}")


# ---------------------------------------------------------------------------
# Sessions REST
# ---------------------------------------------------------------------------
@app.post("/sessions", response_model=SessionOut, status_code=201)
def create_session(body: SessionCreate, db: SASession = Depends(get_db)):
    user = _get_or_create_default_user(db)
    sess = ChatSession(
        user_id=user.id,
        title=(body.title or "New chat").strip()[:160] or "New chat",
    )
    db.add(sess)
    db.commit()
    db.refresh(sess)
    return _session_to_dto(sess)


@app.get("/sessions", response_model=list[SessionOut])
def list_sessions(
    limit: int = Query(default=50, ge=1, le=200),
    db: SASession = Depends(get_db),
):
    user = _get_or_create_default_user(db)
    rows = (
        db.query(ChatSession)
        .filter(ChatSession.user_id == user.id)
        .order_by(ChatSession.updated_at.desc())
        .limit(limit)
        .all()
    )
    return [_session_to_dto(r) for r in rows]


@app.get("/sessions/{session_id}", response_model=SessionDetail)
def get_session(session_id: str, db: SASession = Depends(get_db)):
    user = _get_or_create_default_user(db)
    s = db.query(ChatSession).filter(
        ChatSession.session_id == session_id,
        ChatSession.user_id == user.id,
    ).one_or_none()
    if s is None:
        raise HTTPException(status_code=404, detail="Session not found")
    return SessionDetail(
        session_id=s.session_id,
        title=s.title,
        created_at=s.created_at,
        updated_at=s.updated_at,
        message_count=len(s.messages),
        messages=[_message_to_dict(m) for m in s.messages],
    )


@app.get("/sessions/{session_id}/messages", response_model=list[MessageOut])
def get_session_messages(session_id: str, db: SASession = Depends(get_db)):
    user = _get_or_create_default_user(db)
    s = db.query(ChatSession).filter(
        ChatSession.session_id == session_id,
        ChatSession.user_id == user.id,
    ).one_or_none()
    if s is None:
        raise HTTPException(status_code=404, detail="Session not found")
    return [
        MessageOut(
            id=m.id,
            role=m.role,
            content=m.content,
            sentiment_label=m.sentiment_label,
            sentiment_confidence=m.sentiment_confidence,
            llm_provider=m.llm_provider,
            llm_model=m.llm_model,
            created_at=m.created_at,
        )
        for m in s.messages
    ]


@app.patch("/sessions/{session_id}", response_model=SessionOut)
def update_session(session_id: str, body: SessionUpdate, db: SASession = Depends(get_db)):
    user = _get_or_create_default_user(db)
    s = db.query(ChatSession).filter(
        ChatSession.session_id == session_id,
        ChatSession.user_id == user.id,
    ).one_or_none()
    if s is None:
        raise HTTPException(status_code=404, detail="Session not found")
    s.title = body.title[:160]
    s.updated_at = utcnow()
    db.commit()
    db.refresh(s)
    return _session_to_dto(s)


@app.delete("/sessions/{session_id}", status_code=204)
def delete_session(session_id: str, db: SASession = Depends(get_db)):
    user = _get_or_create_default_user(db)
    s = db.query(ChatSession).filter(
        ChatSession.session_id == session_id,
        ChatSession.user_id == user.id,
    ).one_or_none()
    if s is None:
        raise HTTPException(status_code=404, detail="Session not found")
    db.delete(s)
    db.commit()
    return None


# ---------------------------------------------------------------------------
# LLM Benchmark / Evaluation endpoint
# ---------------------------------------------------------------------------
# Matches the "Evaluate and optimize machine learning models with LLM
# evaluation, NLP, Python, and Hugging Face" requirement.
#
# POST /benchmark
# Runs every installed+available LLM adapter through a curated NLP prompt
# suite and reports per-model: latency (avg/p95), output tokens, sentiment
# classification accuracy vs expected labels, a quality score (judge LLM or
# heuristic), an estimated cost, and an overall 0–100 composite score.

_BENCHMARK_PROMPTS: list[tuple[str, str]] = [
    ("Explain gradient descent to a 10-year-old in 3 sentences.", "POSITIVE"),
    ("Give me 3 concrete resume bullets for an AI engineer using Python + Flutter + PostgreSQL.", "POSITIVE"),
    ("My code has a null pointer bug and the user is really frustrated with me.", "NEGATIVE"),
    ("Summarise the benefits of using FastAPI over Flask in production.", "POSITIVE"),
    ("Prove 1+1=2 with a short logical argument.", "POSITIVE"),
    ("I had a terrible day debugging production and nothing is working.", "NEGATIVE"),
    ("Compare CNNs and Transformers for image classification — pros/cons of each.", "POSITIVE"),
    ("Write a friendly job-acceptance email to a candidate named Alex.", "POSITIVE"),
]


def _heuristic_quality(prompt: str, reply: str) -> float:
    if not reply:
        return 0.0
    p_words = [w.lower() for w in prompt.split() if len(w) >= 5]
    r_lower = reply.lower()
    overlap = sum(1 for w in p_words if w in r_lower)
    overlap_score = min(1.0, overlap / max(1, len(p_words) * 0.3))
    length = len(reply)
    length_score = (
        length / 100 if length < 100 else
        1.0 if length < 900 else
        max(0.0, 1.0 - (length - 900) / 2000)
    )
    unique_frac = len(set(r_lower.split())) / max(1, len(r_lower.split()))
    rep_penalty = max(0.4, unique_frac)
    score = 0.4 * overlap_score + 0.45 * length_score + 0.15 * rep_penalty
    return round(score, 3)


async def _judge_llm_quality(prompt: str, reply: str) -> tuple[float, str]:
    """If an OpenAI-compatible judge model is configured, use it; else heuristic."""
    base = os.getenv("JUDGE_BASE_URL") or os.getenv("OPENAI_COMPAT_BASE_URL") or ""
    key = os.getenv("JUDGE_API_KEY") or os.getenv("OPENAI_COMPAT_API_KEY") or os.getenv("OPENAI_API_KEY") or ""
    model = os.getenv("JUDGE_MODEL") or os.getenv("OPENAI_COMPAT_MODEL") or os.getenv("OPENAI_MODEL") or "gpt-4o-mini"
    if not base and not key.startswith("sk-"):
        return _heuristic_quality(prompt, reply), "heuristic"
    try:
        from openai import OpenAI
        kwargs: dict = {"api_key": key or "dummy"}
        if base:
            kwargs["base_url"] = base
        client = OpenAI(**kwargs)
        resp = client.chat.completions.create(
            model=model,
            temperature=0.1,
            max_tokens=256,
            response_format={"type": "json_object"},
            messages=[
                {"role": "system", "content": "Rate the reply quality 0.00–1.00 considering helpfulness, correctness, conciseness, coherence. Respond JSON: {\"score\": number, \"rationale\": string}."},
                {"role": "user", "content": f"PROMPT:\n{prompt}\n\nREPLY:\n{reply}"},
            ],
            timeout=30.0,
        )
        data = __import__("json").loads(resp.choices[0].message.content or "{}")
        return round(max(0.0, min(1.0, float(data.get("score", 0)))), 3), model
    except Exception as e:
        logger.warning(f"Judge LLM failed, using heuristic: {e}")
        return _heuristic_quality(prompt, reply), "heuristic"


def _cost_estimate(provider_name: str, model_label: str, in_tok: int, out_tok: int) -> float:
    # Rough $/1k tokens for common choices (used for ranking only)
    cost_map = {
        "openai:gpt-4o-mini": (0.15 / 1000, 0.60 / 1000),
        "openai:gpt-4o": (2.5 / 1000, 10.0 / 1000),
        "openai_compat:llama3": (0.2 / 1000, 0.8 / 1000),
        "local:distilgpt2": (0.0, 0.0),
        "local:rule-based": (0.0, 0.0),
        "hf_inference:HuggingFaceH4/zephyr-7b-beta": (0.0, 0.0),
    }
    k = f"{provider_name}:{model_label.split(':', 1)[-1]}" if ":" in model_label else f"{provider_name}:{model_label}"
    # Fallback to provider-wide default when model not recognised
    if k not in cost_map:
        defaults = {"openai": (3.0 / 1000, 12.0 / 1000), "openai_compat": (0.3 / 1000, 1.0 / 1000)}
        ci, co = defaults.get(provider_name, (0.0, 0.0))
    else:
        ci, co = cost_map[k]
    return round(in_tok * ci + out_tok * co, 6)


class BenchmarkResponse(BaseModel):
    timestamp: str
    prompts: int
    results: list[dict]
    ranking: list[dict]
    recommendation: Optional[str]


class BenchmarkRequest(BaseModel):
    use_judge_llm: bool = True
    extra_prompts: Optional[list[dict]] = None  # [{prompt, expectedSentiment}]


@app.post("/benchmark", response_model=BenchmarkResponse)
async def run_benchmark(req: BenchmarkRequest = BenchmarkRequest()):
    """
    Runs the NLP/Latency/Cost benchmark suite across every instantiated LLM.
    Returns per-model metrics, a composite score (0–100) and a recommendation.
    """
    import time as _time
    import statistics

    prompts = [
        (p, s) for (p, s) in _BENCHMARK_PROMPTS
    ]
    if req.extra_prompts:
        for ep in req.extra_prompts:
            p = str(ep.get("prompt", "")).strip()
            s = str(ep.get("expectedSentiment", "")).upper() or "POSITIVE"
            if p:
                prompts.append((p, s))

    results: list[dict] = []
    # Only evaluate providers that are actually available
    providers_to_eval = [(k, v) for (k, v) in _instantiated_llms.items() if v.available]
    # Also include the active LLM in case fallback logic picked something extra
    seen: set[str] = set()
    for pname, pobj in providers_to_eval + [(active_llm().name, active_llm())]:
        if pname in seen:
            continue
        seen.add(pname)
        latencies: list[int] = []
        sentiments: list[bool] = []
        qualities: list[float] = []
        total_in = 0
        total_out = 0
        errors = 0
        runs = []
        for prompt, expected_sentiment in prompts:
            t0 = _time.perf_counter()
            try:
                # Build minimal messages for this prompt (no history)
                msgs = build_messages_for_llm(ChatRequest(message=prompt), db_history=None)
                if isinstance(pobj, LocalLLM):
                    reply = pobj.generate(msgs, sentiment_label=expected_sentiment)
                else:
                    reply = pobj.generate(msgs)
                latency_ms = round((_time.perf_counter() - t0) * 1000)
                if not reply:
                    raise RuntimeError("empty reply")
            except Exception as e:
                errors += 1
                runs.append({"prompt": prompt[:80], "error": str(e)})
                continue

            in_tok = max(1, len(prompt) // 4)
            out_tok = max(1, len(reply) // 4)
            total_in += in_tok
            total_out += out_tok
            latencies.append(latency_ms)

            # NLP check: compare classifier sentiment to expected label
            lbl, _ = classify_sentiment(prompt)
            sentiments.append((lbl or "").upper() == (expected_sentiment or "").upper())

            # Quality score
            if req.use_judge_llm:
                q, judged_by = await _judge_llm_quality(prompt, reply)
            else:
                q, judged_by = _heuristic_quality(prompt, reply), "heuristic"
            qualities.append(q)

            runs.append({
                "prompt": prompt[:80],
                "reply": reply[:200],
                "latency_ms": latency_ms,
                "output_tokens": out_tok,
                "sentiment_label": lbl,
                "expected_sentiment": expected_sentiment,
                "quality": q,
                "quality_judge": judged_by,
            })

        est_cost = _cost_estimate(pname, pobj.model_label, total_in, total_out)
        avg_lat = round(statistics.mean(latencies), 1) if latencies else 0
        p95_lat = sorted(latencies)[int(0.95 * len(latencies)) - 1] if latencies else 0
        sent_acc = round(sum(sentiments) / len(sentiments), 3) if sentiments else None
        avg_q = round(sum(qualities) / len(qualities), 3) if qualities else 0.0
        completed = max(1, len(runs) - errors)
        error_penalty = 1.0 - (errors / max(1, len(prompts)))

        # Composite score (0–100): quality 40, latency 25, NLP accuracy 20, cost 15
        q_score = avg_q * 40
        lat_score = max(0.0, 25 - min(25, (p95_lat / 10_000) * 25)) if p95_lat else 0
        nlp_score = (sent_acc or 0) * 20
        cost_score = max(0.0, 15 - min(15, (est_cost / 0.5) * 15)) if est_cost else 15
        overall = round((q_score + lat_score + nlp_score + cost_score) * error_penalty, 2)

        results.append({
            "provider": pname,
            "model": pobj.model_label,
            "runs_completed": completed,
            "errors": errors,
            "avg_latency_ms": avg_lat,
            "p95_latency_ms": p95_lat,
            "input_tokens": total_in,
            "output_tokens": total_out,
            "sentiment_accuracy": sent_acc,
            "avg_quality": avg_q,
            "estimated_cost_usd": est_cost,
            "overall_score": overall,
            "runs": runs,
        })

    results.sort(key=lambda r: r["overall_score"], reverse=True)
    ranking = [
        {"rank": i + 1, "provider": r["provider"], "model": r["model"], "overall_score": r["overall_score"]}
        for i, r in enumerate(results)
    ]
    recommendation = results[0]["provider"] if results else None

    return BenchmarkResponse(
        timestamp=utcnow().isoformat() + "Z",
        prompts=len(prompts),
        results=results,
        ranking=ranking,
        recommendation=recommendation,
    )
