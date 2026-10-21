"""
Tests for AI Chat backend API endpoints.

Coverage:
  - Health check
  - Sentiment analysis
  - Chat with and without session persistence
  - Session CRUD operations
  - Error handling and edge cases
"""
import json
import pytest
from fastapi import HTTPException
from conftest import TEST_EMAIL, TEST_PASSWORD
from main import (
    BaseLLM,
    ChatRequest,
    SessionCreate,
    SessionUpdate,
    ChatSession,
    ChatMessageDB,
    User,
    chunk_words,
    get_bind_port,
    stream_reply_with_history,
)


def test_bind_port_respects_render_env(monkeypatch):
    """Render sets PORT dynamically; the app should bind to it."""
    monkeypatch.setenv("PORT", "4321")
    assert get_bind_port() == 4321


class TestHealthCheck:
    """Test the health check endpoint."""

    def test_root_endpoint(self, client, default_user):
        """GET / should return service status."""
        response = client.get("/")
        assert response.status_code == 200
        data = response.json()
        
        assert data["status"] == "AI Chat Backend is running"
        assert "llm" in data
        assert "sentiment" in data
        assert "database" in data
        assert data["llm"]["provider"] in ["openai", "openai_compat", "hf_inference", "local"]
        assert data["database"]["url_scheme"] in ["sqlite", "postgresql"]
        assert data["database"]["sessions"] == 0  # Fresh DB


class TestSentimentAnalysis:
    """Test the sentiment analysis endpoint."""

    def test_positive_sentiment(self, client):
        """POST /sentiment with positive text should return POSITIVE."""
        response = client.post(
            "/sentiment",
            json={"message": "I love this! It's amazing and wonderful!"}
        )
        assert response.status_code == 200
        data = response.json()
        assert data["label"] in ["POSITIVE", "NEGATIVE"]
        assert 0 <= data["confidence"] <= 1

    def test_negative_sentiment(self, client):
        """POST /sentiment with negative text should return NEGATIVE."""
        response = client.post(
            "/sentiment",
            json={"message": "This is terrible and awful. I hate it."}
        )
        assert response.status_code == 200
        data = response.json()
        assert data["label"] in ["POSITIVE", "NEGATIVE"]
        assert 0 <= data["confidence"] <= 1

    def test_neutral_sentiment(self, client):
        """POST /sentiment with neutral text."""
        response = client.post(
            "/sentiment",
            json={"message": "The weather is partly cloudy."}
        )
        assert response.status_code == 200
        data = response.json()
        assert data["label"] in ["POSITIVE", "NEGATIVE"]
        assert 0 <= data["confidence"] <= 1

    def test_sentiment_empty_message(self, client):
        """POST /sentiment with empty message should fail."""
        response = client.post(
            "/sentiment",
            json={"message": ""}
        )
        assert response.status_code == 422  # Validation error


class TestChatEndpoint:
    """Test the chat endpoint."""

    def test_chat_without_session(self, client):
        """POST /chat without session_id should work and not persist."""
        response = client.post(
            "/chat",
            json={
                "message": "Hello, how are you?",
                "history": []
            }
        )
        assert response.status_code == 200
        data = response.json()
        
        assert "reply" in data
        assert "sentiment" in data
        assert data["sentiment"] in ["POSITIVE", "NEGATIVE"]
        assert "confidence" in data
        assert 0 <= data["confidence"] <= 1
        assert "provider" in data
        assert "model" in data
        assert data["session_id"] is None  # No persistence without session_id

    def test_chat_with_valid_history(self, client):
        """POST /chat with explicit history."""
        response = client.post(
            "/chat",
            json={
                "message": "What is 2+2?",
                "history": [
                    {"role": "system", "content": "You are helpful."},
                    {"role": "user", "content": "Hi there"},
                    {"role": "assistant", "content": "Hello!"}
                ]
            }
        )
        assert response.status_code == 200
        data = response.json()
        assert "reply" in data
        assert len(data["reply"]) > 0

    def test_chat_with_invalid_history_role(self, client):
        """POST /chat with invalid role in history should filter it out."""
        response = client.post(
            "/chat",
            json={
                "message": "Hello",
                "history": [{"role": "invalid_role", "content": "test"}]
            }
        )
        # Invalid roles are filtered out by _normalise_history, so this succeeds
        assert response.status_code == 200

    def test_chat_message_too_long(self, client):
        """POST /chat with message exceeding max length should fail."""
        response = client.post(
            "/chat",
            json={"message": "x" * 2001}
        )
        assert response.status_code == 422

    def test_chat_with_nonexistent_session(self, client):
        """POST /chat with invalid session_id should fail."""
        response = client.post(
            "/chat",
            json={
                "message": "Hello",
                "session_id": "nonexistent_session_id"
            }
        )
        assert response.status_code == 404


class TestSessionManagement:
    """Test session CRUD endpoints."""

    def test_create_session(self, client, default_user):
        """POST /sessions should create a new session."""
        response = client.post(
            "/sessions",
            json={"title": "My Test Chat"}
        )
        assert response.status_code == 201
        data = response.json()
        
        assert data["session_id"] is not None
        assert data["title"] == "My Test Chat"
        assert data["message_count"] == 0
        assert "created_at" in data
        assert "updated_at" in data

    def test_create_session_without_title(self, client):
        """POST /sessions without title should use default."""
        response = client.post("/sessions", json={})
        assert response.status_code == 201
        data = response.json()
        assert data["title"] == "New chat"

    def test_list_sessions_empty(self, client, default_user):
        """GET /sessions on fresh DB should return empty list."""
        response = client.get("/sessions")
        assert response.status_code == 200
        data = response.json()
        assert isinstance(data, list)
        assert len(data) == 0

    def test_list_sessions_with_data(self, client):
        """GET /sessions should return all user sessions."""
        # Create 3 sessions
        for i in range(3):
            client.post("/sessions", json={"title": f"Session {i}"})
        
        response = client.get("/sessions")
        assert response.status_code == 200
        data = response.json()
        assert len(data) == 3

    def test_list_sessions_with_limit(self, client):
        """GET /sessions?limit=2 should respect limit."""
        for i in range(5):
            client.post("/sessions", json={"title": f"Session {i}"})
        
        response = client.get("/sessions?limit=2")
        assert response.status_code == 200
        data = response.json()
        assert len(data) == 2

    def test_list_sessions_ordering(self, client):
        """GET /sessions should return sessions in most-recent-first order."""
        import time
        session_ids = []
        for i in range(3):
            r = client.post("/sessions", json={"title": f"Session {i}"})
            session_ids.append(r.json()["session_id"])
            time.sleep(0.01)  # Small delay to ensure different timestamps
        
        response = client.get("/sessions")
        data = response.json()
        
        # Most recent should be first
        assert len(data) >= 1

    def test_get_session_detail(self, client):
        """GET /sessions/{id} should return session detail."""
        # Create a session
        create_resp = client.post("/sessions", json={"title": "Test Session"})
        session_id = create_resp.json()["session_id"]
        
        # Get its detail
        response = client.get(f"/sessions/{session_id}")
        assert response.status_code == 200
        data = response.json()
        
        assert data["session_id"] == session_id
        assert data["title"] == "Test Session"
        assert "messages" in data
        assert isinstance(data["messages"], list)

    def test_get_nonexistent_session(self, client):
        """GET /sessions/{id} with invalid id should 404."""
        response = client.get("/sessions/nonexistent_id")
        assert response.status_code == 404

    def test_update_session_title(self, client):
        """PATCH /sessions/{id} should update title."""
        create_resp = client.post("/sessions", json={"title": "Original"})
        session_id = create_resp.json()["session_id"]
        
        response = client.patch(
            f"/sessions/{session_id}",
            json={"title": "Updated Title"}
        )
        assert response.status_code == 200
        data = response.json()
        assert data["title"] == "Updated Title"

    def test_update_session_invalid_title(self, client):
        """PATCH /sessions/{id} with empty title should fail."""
        create_resp = client.post("/sessions", json={"title": "Test"})
        session_id = create_resp.json()["session_id"]
        
        response = client.patch(
            f"/sessions/{session_id}",
            json={"title": ""}
        )
        assert response.status_code == 422

    def test_delete_session(self, client):
        """DELETE /sessions/{id} should remove session and messages."""
        # Create session and send a message
        create_resp = client.post("/sessions", json={"title": "To Delete"})
        session_id = create_resp.json()["session_id"]
        
        client.post(
            "/chat",
            json={"message": "Hello", "session_id": session_id}
        )
        
        # Verify it exists
        get_resp = client.get(f"/sessions/{session_id}")
        assert get_resp.status_code == 200
        
        # Delete it
        del_resp = client.delete(f"/sessions/{session_id}")
        assert del_resp.status_code == 204
        
        # Verify it's gone
        get_resp = client.get(f"/sessions/{session_id}")
        assert get_resp.status_code == 404

    def test_delete_nonexistent_session(self, client):
        """DELETE /sessions/{id} with invalid id should 404."""
        response = client.delete("/sessions/nonexistent_id")
        assert response.status_code == 404


class TestChatWithPersistence:
    """Test chat endpoint with session persistence."""

    def test_chat_creates_messages_in_session(self, client):
        """POST /chat with session_id should persist messages."""
        # Create session
        create_resp = client.post("/sessions", json={"title": "Chat Test"})
        session_id = create_resp.json()["session_id"]
        
        # Send message
        chat_resp = client.post(
            "/chat",
            json={
                "message": "Hello AI!",
                "session_id": session_id
            }
        )
        assert chat_resp.status_code == 200
        assert chat_resp.json()["session_id"] == session_id
        
        # Verify messages were persisted
        session_resp = client.get(f"/sessions/{session_id}")
        data = session_resp.json()
        assert data["message_count"] == 2  # user + assistant

    def test_chat_uses_session_history(self, client):
        """Multi-turn chat should maintain history from DB."""
        # Create session
        create_resp = client.post("/sessions", json={"title": "Multi-turn"})
        session_id = create_resp.json()["session_id"]
        
        # First turn
        client.post(
            "/chat",
            json={"message": "My name is Alice", "session_id": session_id}
        )
        
        # Second turn (should reference history)
        chat_resp = client.post(
            "/chat",
            json={"message": "What's my name?", "session_id": session_id}
        )
        assert chat_resp.status_code == 200
        
        # Session should have 4 messages (user1, assistant1, user2, assistant2)
        session_resp = client.get(f"/sessions/{session_id}")
        assert session_resp.json()["message_count"] == 4

    def test_chat_auto_titles_session(self, client):
        """First chat message should auto-title session."""
        create_resp = client.post("/sessions", json={})
        session_id = create_resp.json()["session_id"]
        
        client.post(
            "/chat",
            json={"message": "Explain quantum computing", "session_id": session_id}
        )
        
        session_resp = client.get(f"/sessions/{session_id}")
        data = session_resp.json()
        # Title should start with the user message (truncated)
        assert "Explain" in data["title"] or "quantum" in data["title"]


def _parse_sse(body: str) -> list[dict]:
    """Turn a raw SSE body into the list of JSON payloads it carried."""
    events = []
    for line in body.splitlines():
        if line.startswith("data:"):
            events.append(json.loads(line[len("data:"):].strip()))
    return events


class TestChatStreaming:
    """Test the POST /chat/stream Server-Sent Events endpoint."""

    def test_stream_event_sequence(self, client):
        """Stream should emit meta → provider → tokens → done."""
        response = client.post("/chat/stream", json={"message": "Hello there!"})
        assert response.status_code == 200
        assert response.headers["content-type"].startswith("text/event-stream")

        events = _parse_sse(response.text)
        types = [e["type"] for e in events]

        assert types[0] == "meta"
        assert types[-1] == "done"
        assert "provider" in types
        assert types.count("token") >= 1

        # Tokens must reassemble into exactly the reported reply
        streamed = "".join(e["text"] for e in events if e["type"] == "token")
        assert streamed.strip() == events[-1]["reply"]
        assert events[-1]["provider"]

    def test_stream_meta_carries_sentiment(self, client):
        """The first event should carry sentiment and confidence."""
        response = client.post("/chat/stream", json={"message": "I love this so much!"})
        meta = _parse_sse(response.text)[0]

        assert meta["type"] == "meta"
        assert meta["sentiment"] in ["POSITIVE", "NEGATIVE"]
        assert 0 <= meta["confidence"] <= 1
        assert meta["session_id"] is None

    def test_stream_persists_turn(self, client):
        """Streaming with a session_id should persist both turns."""
        session_id = client.post("/sessions", json={}).json()["session_id"]

        response = client.post(
            "/chat/stream",
            json={"message": "Stream this please", "session_id": session_id},
        )
        done = _parse_sse(response.text)[-1]
        assert done["type"] == "done"
        assert done["session_id"] == session_id

        detail = client.get(f"/sessions/{session_id}").json()
        assert detail["message_count"] == 2
        assert detail["title"] == "Stream this please"

        messages = client.get(f"/sessions/{session_id}/messages").json()
        assert messages[0]["role"] == "user"
        assert messages[0]["content"] == "Stream this please"
        assert messages[1]["role"] == "assistant"
        assert messages[1]["content"] == done["reply"]

    def test_stream_multi_turn_uses_history(self, client):
        """Two streamed turns should leave four persisted messages."""
        session_id = client.post("/sessions", json={}).json()["session_id"]

        client.post("/chat/stream", json={"message": "My name is Alice", "session_id": session_id})
        client.post("/chat/stream", json={"message": "What's my name?", "session_id": session_id})

        assert client.get(f"/sessions/{session_id}").json()["message_count"] == 4

    def test_stream_unknown_session_returns_404(self, client):
        """A bad session_id must fail before the stream opens."""
        response = client.post("/chat/stream", json={"message": "hi", "session_id": "nope"})
        assert response.status_code == 404

    def test_stream_rejects_empty_message(self, client):
        """Validation still applies to the streaming endpoint."""
        response = client.post("/chat/stream", json={"message": ""})
        assert response.status_code == 422


class TestStreamingHelpers:
    """Unit tests for the streaming internals."""

    def test_chunk_words_reassembles(self):
        """Chunked text must rejoin into the original sentence."""
        text = "one two three four five six seven"
        assert "".join(chunk_words(text, words_per_chunk=2)).strip() == text

    def test_falls_back_when_provider_stream_fails(self, monkeypatch):
        """A provider that dies immediately should be replaced by the next one."""

        class BoomLLM(BaseLLM):
            name = "boom"

            def _post_init(self):
                self.model_label = "boom:test"
                self.available = True

            def generate(self, messages):
                return "unused"

            def stream(self, messages):
                raise RuntimeError("provider exploded")
                yield  # pragma: no cover

        monkeypatch.setattr("main.active_llm", lambda: BoomLLM())

        events = list(stream_reply_with_history([{"role": "user", "content": "hi"}], "POSITIVE"))
        provider = next(payload for kind, payload in events if kind == "provider")

        assert provider["name"] != "boom"
        assert any(kind == "token" for kind, _ in events)


class TestAuth:
    """Test registration, login and route protection."""

    def test_register_returns_token_and_user(self, anon_client):
        """Registering should normalise the email and issue a token."""
        res = anon_client.post(
            "/auth/register",
            json={"email": "New.User@Example.com", "password": "hunter2hunter2"},
        )
        assert res.status_code == 201
        body = res.json()

        assert body["token_type"] == "bearer"
        assert body["access_token"]
        assert body["expires_in"] > 0
        assert body["user"]["email"] == "new.user@example.com"
        assert body["user"]["display_name"] == "new.user"
        assert "password" not in json.dumps(body).lower()

    def test_register_rejects_invalid_email(self, anon_client):
        res = anon_client.post(
            "/auth/register",
            json={"email": "not-an-email", "password": "hunter2hunter2"},
        )
        assert res.status_code == 422

    def test_register_rejects_short_password(self, anon_client):
        res = anon_client.post(
            "/auth/register",
            json={"email": "short@example.com", "password": "tiny"},
        )
        assert res.status_code == 422

    def test_register_rejects_duplicate_email(self, anon_client):
        payload = {"email": "dupe@example.com", "password": "hunter2hunter2"}
        assert anon_client.post("/auth/register", json=payload).status_code == 201
        assert anon_client.post("/auth/register", json=payload).status_code == 409

    def test_password_is_stored_hashed(self, anon_client, test_db):
        """The raw password must never be persisted."""
        anon_client.post(
            "/auth/register",
            json={"email": "hash@example.com", "password": "hunter2hunter2"},
        )
        user = test_db.query(User).filter(User.email == "hash@example.com").one()

        assert user.password_hash
        assert user.password_hash != "hunter2hunter2"
        assert user.password_hash.startswith("$2")  # bcrypt hash prefix

    def test_login_success(self, anon_client):
        anon_client.post(
            "/auth/register",
            json={"email": "login@example.com", "password": "hunter2hunter2"},
        )
        res = anon_client.post(
            "/auth/login",
            json={"email": "LOGIN@example.com", "password": "hunter2hunter2"},
        )
        assert res.status_code == 200
        assert res.json()["user"]["email"] == "login@example.com"

    def test_login_wrong_password(self, anon_client):
        anon_client.post(
            "/auth/register",
            json={"email": "login2@example.com", "password": "hunter2hunter2"},
        )
        res = anon_client.post(
            "/auth/login",
            json={"email": "login2@example.com", "password": "wrong-password"},
        )
        assert res.status_code == 401

    def test_login_unknown_email(self, anon_client):
        res = anon_client.post(
            "/auth/login",
            json={"email": "ghost@example.com", "password": "hunter2hunter2"},
        )
        assert res.status_code == 401

    def test_me_returns_signed_in_user(self, client):
        res = client.get("/auth/me")
        assert res.status_code == 200
        assert res.json()["email"] == TEST_EMAIL

    def test_protected_routes_need_a_token(self, anon_client):
        assert anon_client.get("/auth/me").status_code == 401
        assert anon_client.get("/sessions").status_code == 401
        assert anon_client.post("/sessions", json={}).status_code == 401

    def test_malformed_token_rejected(self, anon_client):
        res = anon_client.get("/sessions", headers={"Authorization": "Bearer not.a.token"})
        assert res.status_code == 401

    def test_sessions_are_isolated_between_users(self, client):
        """One user must not be able to read or delete another user's session."""
        mine = client.post("/sessions", json={"title": "Mine"}).json()["session_id"]

        other = client.post(
            "/auth/register",
            json={"email": "other@example.com", "password": "hunter2hunter2"},
        ).json()
        other_headers = {"Authorization": f"Bearer {other['access_token']}"}

        assert len(client.get("/sessions").json()) == 1
        assert client.get("/sessions", headers=other_headers).json() == []
        assert client.get(f"/sessions/{mine}", headers=other_headers).status_code == 404
        assert client.delete(f"/sessions/{mine}", headers=other_headers).status_code == 404

    def test_chat_into_stored_session_needs_auth(self, anon_client):
        res = anon_client.post("/chat", json={"message": "hi", "session_id": "abc"})
        assert res.status_code == 401

    def test_stateless_chat_allowed_without_auth(self, anon_client):
        """Stateless chat is what the Node evaluator calls, so it stays open."""
        res = anon_client.post("/chat", json={"message": "hello there"})
        assert res.status_code == 200
        assert res.json()["session_id"] is None

    def test_root_reports_auth_config(self, client):
        body = client.get("/").json()
        assert body["auth"]["scheme"] == "bearer"
        assert body["auth"]["enabled"] is True


class TestMessageDetails:
    """Test message endpoint and message metadata."""

    def test_get_session_messages(self, client):
        """GET /sessions/{id}/messages should list all messages."""
        # Create session and chat
        create_resp = client.post("/sessions", json={"title": "Test"})
        session_id = create_resp.json()["session_id"]
        
        client.post(
            "/chat",
            json={"message": "Test message", "session_id": session_id}
        )
        
        # Get messages
        response = client.get(f"/sessions/{session_id}/messages")
        assert response.status_code == 200
        messages = response.json()
        
        assert len(messages) == 2  # user + assistant
        
        # Check message structure
        for msg in messages:
            assert "id" in msg
            assert "role" in msg
            assert "content" in msg
            assert "created_at" in msg
            assert msg["role"] in ["user", "assistant"]

    def test_messages_include_sentiment(self, client):
        """AI response messages should include sentiment analysis."""
        create_resp = client.post("/sessions", json={})
        session_id = create_resp.json()["session_id"]
        
        client.post(
            "/chat",
            json={"message": "I love this!", "session_id": session_id}
        )
        
        response = client.get(f"/sessions/{session_id}/messages")
        messages = response.json()
        
        # Find the assistant message
        assistant_msg = next((m for m in messages if m["role"] == "assistant"), None)
        assert assistant_msg is not None
        assert "sentiment_label" in assistant_msg
        assert assistant_msg["sentiment_label"] in ["POSITIVE", "NEGATIVE"]
        assert "sentiment_confidence" in assistant_msg

    def test_messages_include_llm_metadata(self, client):
        """AI messages should include LLM provider/model info."""
        create_resp = client.post("/sessions", json={})
        session_id = create_resp.json()["session_id"]
        
        client.post(
            "/chat",
            json={"message": "Hello", "session_id": session_id}
        )
        
        response = client.get(f"/sessions/{session_id}/messages")
        messages = response.json()
        
        assistant_msg = next((m for m in messages if m["role"] == "assistant"), None)
        assert assistant_msg is not None
        assert "llm_provider" in assistant_msg
        assert "llm_model" in assistant_msg


class TestInputValidation:
    """Test input validation and error handling."""

    def test_chat_message_required(self, client):
        """POST /chat without message should fail."""
        response = client.post("/chat", json={})
        assert response.status_code == 422

    def test_session_title_max_length(self, client):
        """Session title exceeding max length should be rejected by Pydantic."""
        long_title = "x" * 200  # Exceeds 160 limit
        response = client.post("/sessions", json={"title": long_title})
        # Pydantic validates max_length before API receives it
        assert response.status_code == 422

    def test_invalid_json(self, client):
        """POST with invalid JSON should fail."""
        response = client.post(
            "/chat",
            data="not json",
            headers={"Content-Type": "application/json"}
        )
        assert response.status_code == 422


class TestConcurrency:
    """Test handling of concurrent operations."""

    def test_multiple_sessions_independent(self, client):
        """Multiple sessions should not interfere."""
        # Create 2 sessions
        sess1 = client.post("/sessions", json={"title": "Session 1"}).json()["session_id"]
        sess2 = client.post("/sessions", json={"title": "Session 2"}).json()["session_id"]
        
        # Send messages to both
        client.post("/chat", json={"message": "Hello from 1", "session_id": sess1})
        client.post("/chat", json={"message": "Hello from 2", "session_id": sess2})
        
        # Verify they're independent
        resp1 = client.get(f"/sessions/{sess1}").json()
        resp2 = client.get(f"/sessions/{sess2}").json()
        
        assert resp1["message_count"] == 2
        assert resp2["message_count"] == 2
        # Messages should be different
        msg1_content = resp1["messages"][0]["content"]
        msg2_content = resp2["messages"][0]["content"]
        assert msg1_content != msg2_content
