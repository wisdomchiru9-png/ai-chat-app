# AI Chat App — Full-Stack AI + Mobile Engineering Portfolio

A production-ready full-stack application combining:
- **Flutter** iOS/Android chat UI with real-time messaging
- **FastAPI** backend with pluggable LLM support (OpenAI, Hugging Face, local)
- **PostgreSQL** persistent chat history with sessions
- **Node.js** LLM evaluation service for model optimization
- **Docker Compose** zero-setup orchestration
- **Pytest** comprehensive API + unit tests

Built to demonstrate expertise in **AI/ML evaluation, mobile development, backend engineering, and DevOps**.

## 🏗️ Project Structure

```
ai-chat-app/
├── backend/
│   ├── main.py              # FastAPI server, LLM adapters, sentiment analysis
│   ├── requirements.txt      # Python dependencies
│   ├── tests/               # 65+ pytest unit & integration tests
│   ├── TESTING.md           # Testing guide
│   ├── Dockerfile           # Python 3.11 + all deps
│   ├── alembic/             # Database migrations (SQLAlchemy)
│   └── scripts/
│       └── run_benchmark.py # ML model benchmarking
├── evaluator-service/
│   ├── src/index.js         # Node.js LLM evaluation + quality scoring
│   ├── package.json         # Express, OpenAI, Pino logging
│   └── Dockerfile
├── flutter_app/
│   ├── lib/
│   │   ├── main.dart        # Chat UI, HTTP client, state management
│   │   └── theme.dart       # Material Design + accessibility
│   └── pubspec.yaml
├── docker-compose.yml       # Multi-service orchestration (Postgres + backend + evaluator)
├── postman/                 # API testing collection
└── README.md
```

## ⚡ Quick Start — Docker (Recommended)

Everything runs in one command:

```bash
docker compose up -d --build
```

Services start:
- **PostgreSQL** on `127.0.0.1:5432` (db: `ai_chat_app`, user: `ai_chat`)
- **Backend** on `http://localhost:8000` (FastAPI + LLM)
- **Evaluator** on `http://localhost:8787` (Node.js ML scorer)

Test the backend:
```bash
curl http://localhost:8000/docs  # Interactive API docs
curl http://localhost:8000/       # Health check
```

Stop everything:
```bash
docker compose down
```

## 🖥️ Local Development

### Prerequisites
- Python 3.9+
- Node.js 20+
- Flutter 3.19+
- PostgreSQL 14+ (optional, SQLite is default)

### Backend (FastAPI)

```bash
cd backend

# Install dependencies
pip install -r requirements.txt

# Copy environment template
cp .env.example .env

# Choose LLM provider in .env:
#   LLM_PROVIDER=local           (default, no API key needed)
#   LLM_PROVIDER=openai          (requires OPENAI_API_KEY)
#   LLM_PROVIDER=openai_compat   (e.g., Ollama, Together, Groq)
#   LLM_PROVIDER=hf_inference    (Hugging Face Inference API)

# Run server
uvicorn main:app --reload --host 0.0.0.0 --port 8000
```

API docs: http://localhost:8000/docs

**First run** downloads Hugging Face sentiment model (~250MB) — cached locally after.

### Run Tests

```bash
cd backend

# Install test dependencies (already in requirements.txt)
pip install -r requirements.txt

# Run all tests
pytest

# Run with coverage
pytest --cov=. --cov-report=html

# See TESTING.md for detailed testing guide
```

**Test coverage:**
- 65+ tests covering API endpoints, models, and business logic
- Uses in-memory SQLite for fast, isolated tests
- Full integration tests with dependency injection

### Evaluator Service (Node.js)

```bash
cd evaluator-service

npm install
npm run dev        # Development mode with auto-reload
# or
npm start          # Production mode
```

Service evaluates LLM providers on:
- **Latency** — Response time (avg, p95)
- **Token efficiency** — Output token count
- **Quality** — Heuristic + judge LLM scoring
- **Accuracy** — Sentiment classification vs expected
- **Cost** — Estimated API costs

### Flutter App

```bash
cd flutter_app

# Install dependencies
flutter pub get

# Run on emulator/device
flutter run

# iOS simulator
flutter run -d macos

# Android emulator
flutter run -d android-emulator
```

**Connecting to backend:**
- Android emulator: `http://10.0.2.2:8000/chat` ← already configured
- iOS simulator: `http://localhost:8000/chat`
- Physical device: `http://<YOUR_IP>:8000/chat`

## 🔌 API Endpoints

### Authentication

JWT bearer tokens (HS256) with bcrypt-hashed passwords.

```
POST   /auth/register     Create an account -> {access_token, token_type, expires_in, user}
POST   /auth/login        Exchange credentials for a token
GET    /auth/me           Return the signed-in user
```

`/sessions*` requires `Authorization: Bearer <token>`. `/chat` and
`/chat/stream` accept the token optionally: pass a `session_id` to persist
into a session, or omit it to stay stateless.

```bash
# Register (or POST /auth/login for an existing account)
TOKEN=$(curl -s -X POST http://localhost:8000/auth/register \
  -H "Content-Type: application/json" \
  -d '{"email":"me@example.com","password":"secret-pass-123"}' \
  | python -c "import sys,json;print(json.load(sys.stdin)['access_token'])")

# Authenticated request
curl http://localhost:8000/sessions -H "Authorization: Bearer $TOKEN"
```

Set `JWT_SECRET` in production. Without it a random secret is generated at
startup, so every restart invalidates all previously issued tokens.

### Chat & Sentiment

```
POST   /chat              Chat with LLM, optionally persist to session
POST   /chat/stream       Same, but streams tokens as Server-Sent Events
POST   /sentiment         Analyze text sentiment (POSITIVE/NEGATIVE)
GET    /                  Health check + service info
```

`POST /chat/stream` emits `data: <json>` events with `type` =
`meta` → `provider` → `token`… → `done` (or `error`). The `token` events
reassemble into the `reply` carried by the final `done` event:

```bash
curl -N -X POST http://localhost:8000/chat/stream \
  -H "Content-Type: application/json" \
  -d '{"message":"Hello AI!"}'
```

### Session Management (requires auth)

```
POST   /sessions                      Create new chat session
GET    /sessions                      List user's sessions (paginated)
GET    /sessions/{id}                 Get session detail + messages
GET    /sessions/{id}/messages        List messages only
PATCH  /sessions/{id}                 Rename session
DELETE /sessions/{id}                 Delete session + messages
```

### Example: Multi-turn Chat

```bash
# Create session
curl -X POST http://localhost:8000/sessions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"title":"My Chat"}'
# Returns: {"session_id": "abc123...", ...}

# Send message
curl -X POST http://localhost:8000/chat \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{
    "message": "Hello, what is machine learning?",
    "session_id": "abc123..."
  }'

# Get session history
curl http://localhost:8000/sessions/abc123... -H "Authorization: Bearer $TOKEN"
```

See `postman/` folder for complete API collection.

## 📊 Database Schema

### SQLite (local) / PostgreSQL (production)

**users** — Single user per instance (portfolio app)
- `id` — Primary key
- `external_id` — Unique identifier
- `display_name` — User display name
- `created_at` — Account creation timestamp

**chat_sessions** — Conversation containers
- `id` — Primary key
- `session_id` — Unique session identifier
- `user_id` — Foreign key to users
- `title` — Session title (auto-set from first message)
- `created_at`, `updated_at` — Timestamps

**chat_messages** — Individual messages
- `id` — Primary key
- `session_id` — Foreign key to chat_sessions
- `role` — "user" or "assistant"
- `content` — Message text
- `sentiment_label` — "POSITIVE" or "NEGATIVE" (for AI responses)
- `sentiment_confidence` — 0.0–1.0 confidence score
- `llm_provider` — Which LLM generated response
- `llm_model` — Specific model identifier
- `created_at` — Message timestamp

Migrations handled by Alembic (in `backend/alembic/`).

## 🤖 LLM Provider Support

### Local (No API key)
```
LLM_PROVIDER=local
```
- Uses `distilgpt2` (local transformers)
- Falls back to rule-based templates if model download fails
- Sentiment analysis with `distilbert`

### OpenAI (GPT-3.5/GPT-4)
```
LLM_PROVIDER=openai
OPENAI_API_KEY=sk-proj-...
OPENAI_MODEL=gpt-4o-mini
```

### OpenAI-Compatible (Ollama, Together, Groq, Anyscale)
```
LLM_PROVIDER=openai_compat
OPENAI_COMPAT_BASE_URL=http://localhost:11434/v1
OPENAI_COMPAT_MODEL=mistral
```

### Hugging Face Inference API
```
LLM_PROVIDER=hf_inference
HUGGINGFACE_TOKEN=hf_...
```

Swap providers anytime by updating `.env` — no code changes needed.

## 🏗️ Architecture Highlights

### Pluggable LLM System
- All providers implement `BaseLLM` interface
- Automatic fallback if provider unavailable
- Provider-specific prompt formatting (e.g., ChatML for Zephyr)

### Sentiment Analysis Pipeline
1. Try Hugging Face Inference API (if token provided)
2. Fall back to local `distilbert` transformer
3. Fall back to keyword-based heuristic (always available)

### Session Persistence
- Optional session-based chat history
- Auto-load context from DB for multi-turn conversations
- Configurable context window trimming (8KB default)

### FastAPI Features
- OpenAPI/Swagger docs auto-generated (`/docs`)
- CORS enabled for cross-origin requests
- Async-capable (future streaming responses)
- Pydantic validation on all inputs

## 📌 What This Demonstrates (Interview Ready)

✅ **Full-Stack Engineering**
- Backend API design (FastAPI, REST)
- Mobile app development (Flutter, Dart)
- Database modeling (SQLAlchemy ORM, migrations)

✅ **AI/ML Expertise**
- Pluggable LLM integration (OpenAI, Hugging Face, local)
- Sentiment analysis (transformers, NLP)
- Model evaluation & benchmarking (Node.js service)

✅ **DevOps & Infrastructure**
- Docker & Docker Compose multi-service orchestration
- Database migrations (Alembic)
- Environment-based configuration

✅ **Software Engineering Best Practices**
- 65+ comprehensive tests (pytest)
- Type hints & validation (Pydantic)
- CORS, error handling, logging
- Git-friendly (migrations, seed data)

## 🚀 Deployment

### On Render.com (Free Tier)

1. Push to GitHub
2. Create PostgreSQL database on Render (the included `render.yaml` blueprint does this for you)
3. Create Web Service pointing to this repo
4. Set environment:
   ```
   LLM_PROVIDER=openai
   OPENAI_API_KEY=sk-...
   DATABASE_URL=postgresql://...
   JWT_SECRET=<run: python -c "import secrets;print(secrets.token_urlsafe(48))">
   ```
5. Run the migrations against the production database:
   ```bash
   cd backend
   DATABASE_URL=postgresql://... alembic upgrade head
   ```
6. Deploy!

The app creates missing tables on startup, but it never adds columns to
existing tables — so run `alembic upgrade head` after any model change,
otherwise queries against the new columns fail.

### On Railway

```bash
railway login
railway init
railway up
```

### On AWS ECS

```bash
docker push username/ai-chat:latest
# Create ECS service with task definition
```

## 🤝 Contributing

Issues & PRs welcome! See [TESTING.md](backend/TESTING.md) for test requirements.

## 📄 License

MIT
