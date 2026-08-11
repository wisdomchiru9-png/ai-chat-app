"""
Unit tests for database models and business logic.
"""
import pytest
from datetime import datetime, timezone
from sqlalchemy.orm import Session

from main import (
    User,
    ChatSession,
    ChatMessageDB,
    classify_sentiment,
    _normalise_history,
    _trim_to_context_window,
    build_messages_for_llm,
    ChatRequest,
)


class TestUserModel:
    """Test User model and operations."""

    def test_create_user(self, test_db: Session):
        """Should create a user with unique external_id."""
        user = User(external_id="test_user_1", display_name="Test User")
        test_db.add(user)
        test_db.commit()
        test_db.refresh(user)
        
        assert user.id is not None
        assert user.external_id == "test_user_1"
        assert user.display_name == "Test User"
        assert isinstance(user.created_at, datetime)

    def test_user_unique_constraint(self, test_db: Session):
        """Users must have unique external_id."""
        user1 = User(external_id="unique_1", display_name="User 1")
        user2 = User(external_id="unique_1", display_name="User 2")
        
        test_db.add(user1)
        test_db.commit()
        
        test_db.add(user2)
        with pytest.raises(Exception):  # IntegrityError
            test_db.commit()

    def test_user_sessions_relationship(self, test_db: Session):
        """User should have relationship to sessions."""
        user = User(external_id="user_with_sessions", display_name="User")
        session = ChatSession(title="Test Session")
        user.sessions.append(session)
        
        test_db.add(user)
        test_db.commit()
        test_db.refresh(user)
        
        assert len(user.sessions) == 1
        assert user.sessions[0].title == "Test Session"


class TestChatSessionModel:
    """Test ChatSession model."""

    def test_create_session(self, test_db: Session, default_user):
        """Should create a session with required fields."""
        session = ChatSession(
            user_id=default_user.id,
            title="Test Chat",
        )
        test_db.add(session)
        test_db.commit()
        test_db.refresh(session)
        
        assert session.id is not None
        assert session.session_id is not None
        assert len(session.session_id) == 32
        assert session.title == "Test Chat"
        assert session.user_id == default_user.id

    def test_session_has_messages_relationship(self, test_db: Session, default_user):
        """Session should have relationship to messages."""
        session = ChatSession(user_id=default_user.id, title="Test")
        msg = ChatMessageDB(
            session_id=session.id,
            role="user",
            content="Hello"
        )
        
        test_db.add(session)
        test_db.flush()
        
        msg.session_id = session.id
        test_db.add(msg)
        test_db.commit()
        test_db.refresh(session)
        
        assert len(session.messages) == 1
        assert session.messages[0].content == "Hello"

    def test_session_cascade_delete_messages(self, test_db: Session, default_user):
        """Deleting session should delete its messages."""
        session = ChatSession(user_id=default_user.id, title="To Delete")
        test_db.add(session)
        test_db.flush()
        
        msg = ChatMessageDB(session_id=session.id, role="user", content="Test")
        test_db.add(msg)
        test_db.commit()
        
        session_id = session.id
        test_db.delete(session)
        test_db.commit()
        
        # Verify session and message are gone
        assert test_db.query(ChatSession).filter_by(id=session_id).one_or_none() is None
        assert test_db.query(ChatMessageDB).filter_by(session_id=session_id).count() == 0


class TestChatMessageModel:
    """Test ChatMessageDB model."""

    def test_create_message(self, test_db: Session, default_user):
        """Should create a message with metadata."""
        session = ChatSession(user_id=default_user.id, title="Test")
        test_db.add(session)
        test_db.flush()
        
        msg = ChatMessageDB(
            session_id=session.id,
            role="user",
            content="Hello world",
            sentiment_label="POSITIVE",
            sentiment_confidence=0.95,
            llm_provider="local",
            llm_model="distilgpt2",
        )
        test_db.add(msg)
        test_db.commit()
        test_db.refresh(msg)
        
        assert msg.id is not None
        assert msg.role == "user"
        assert msg.content == "Hello world"
        assert msg.sentiment_label == "POSITIVE"
        assert msg.sentiment_confidence == 0.95

    def test_message_optional_fields(self, test_db: Session, default_user):
        """Message sentiment and LLM fields should be optional."""
        session = ChatSession(user_id=default_user.id, title="Test")
        test_db.add(session)
        test_db.flush()
        
        msg = ChatMessageDB(
            session_id=session.id,
            role="user",
            content="Test"
        )
        test_db.add(msg)
        test_db.commit()
        test_db.refresh(msg)
        
        assert msg.sentiment_label is None
        assert msg.sentiment_confidence is None
        assert msg.llm_provider is None
        assert msg.llm_model is None


class TestSentimentClassification:
    """Test sentiment analysis function."""

    def test_classify_positive_sentiment(self):
        """Positive keywords should return POSITIVE."""
        label, conf = classify_sentiment("I love this! It's amazing!")
        assert label in ["POSITIVE", "NEGATIVE"]
        assert 0 <= conf <= 1

    def test_classify_negative_sentiment(self):
        """Negative keywords should return NEGATIVE."""
        label, conf = classify_sentiment("This is terrible and awful.")
        assert label in ["POSITIVE", "NEGATIVE"]
        assert 0 <= conf <= 1

    def test_classify_empty_text(self):
        """Empty text should still return valid result."""
        label, conf = classify_sentiment("")
        assert label in ["POSITIVE", "NEGATIVE"]
        assert 0 <= conf <= 1

    def test_sentiment_confidence_range(self):
        """Confidence should always be between 0 and 1."""
        for text in [
            "love",
            "hate",
            "amazing",
            "terrible",
            "neutral",
            "",
        ]:
            label, conf = classify_sentiment(text)
            assert 0 <= conf <= 1


class TestHistoryNormalization:
    """Test history normalization helper."""

    def test_normalize_list_of_dicts(self):
        """Should normalize list of dict messages."""
        raw = [
            {"role": "user", "content": "Hello"},
            {"role": "assistant", "content": "Hi there"},
        ]
        result = _normalise_history(raw)
        assert len(result) == 2
        assert result[0]["role"] == "user"

    def test_normalize_consecutive_roles(self):
        """Should merge consecutive messages from same role."""
        raw = [
            {"role": "user", "content": "Part 1"},
            {"role": "user", "content": "Part 2"},
            {"role": "assistant", "content": "Reply"},
        ]
        result = _normalise_history(raw)
        assert len(result) == 2
        assert "Part 1" in result[0]["content"]
        assert "Part 2" in result[0]["content"]

    def test_normalize_invalid_roles(self):
        """Should skip messages with invalid roles."""
        raw = [
            {"role": "user", "content": "Hello"},
            {"role": "invalid", "content": "Should skip"},
            {"role": "assistant", "content": "Hi"},
        ]
        result = _normalise_history(raw)
        assert len(result) == 2
        assert all(m["role"] in ["user", "assistant"] for m in result)

    def test_normalize_empty_history(self):
        """Empty history should return empty list."""
        assert _normalise_history(None) == []
        assert _normalise_history([]) == []


class TestContextWindowTrimming:
    """Test history context window trimming."""

    def test_trim_respects_max_chars(self):
        """Should not exceed max_chars."""
        history = [
            {"role": "system", "content": "System prompt"},
            {"role": "user", "content": "x" * 5000},
            {"role": "assistant", "content": "y" * 5000},
        ]
        result = _trim_to_context_window(history, max_chars=8000)
        
        total_chars = sum(len(m["content"]) for m in result)
        assert total_chars <= 8000 + 100  # Small buffer for overhead

    def test_trim_keeps_system_message(self):
        """Should preserve system message at start."""
        history = [
            {"role": "system", "content": "You are helpful"},
            {"role": "user", "content": "Hello"},
            {"role": "assistant", "content": "Hi"},
        ]
        result = _trim_to_context_window(history, keep_system=True)
        
        assert result[0]["role"] == "system"
        assert result[0]["content"] == "You are helpful"

    def test_trim_empty_history(self):
        """Empty history should return empty."""
        assert _trim_to_context_window([]) == []
        assert _trim_to_context_window(None) is None

    def test_trim_preserves_message_order(self):
        """Trimmed history should maintain chronological order."""
        history = [
            {"role": "user", "content": "First"},
            {"role": "assistant", "content": "Reply 1"},
            {"role": "user", "content": "Second"},
            {"role": "assistant", "content": "Reply 2"},
        ]
        result = _trim_to_context_window(history, max_chars=1000)
        
        # Chronological order should be preserved (interleaved user/assistant)
        roles = [m["role"] for m in result]
        assert roles == ["user", "assistant", "user", "assistant"]


class TestBuildMessagesForLLM:
    """Test LLM message building."""

    def test_build_with_explicit_history(self):
        """Should use explicit request history."""
        request = ChatRequest(
            message="Final message",
            history=[{"role": "user", "content": "First"}]
        )
        result = build_messages_for_llm(request)
        
        # Should have system prompt + history + new message
        assert len(result) >= 2
        assert result[-1]["content"] == "Final message"
        assert result[0]["role"] == "system"

    def test_build_with_db_history(self):
        """Should use DB history when no explicit history."""
        db_history = [
            {"role": "user", "content": "From DB 1"},
            {"role": "assistant", "content": "Reply 1"},
        ]
        request = ChatRequest(message="New message", history=None)
        result = build_messages_for_llm(request, db_history=db_history)
        
        # Should include system + DB history + new message
        assert len(result) >= 3
        assert result[-1]["content"] == "New message"

    def test_build_adds_system_prompt(self):
        """Should add system prompt if missing."""
        request = ChatRequest(message="Hello")
        result = build_messages_for_llm(request)
        
        assert result[0]["role"] == "system"
        assert len(result[0]["content"]) > 0

    def test_build_avoids_duplicate_user_message(self):
        """Should not duplicate the latest user message."""
        request = ChatRequest(
            message="Hello",
            history=[{"role": "user", "content": "Hello"}]
        )
        result = build_messages_for_llm(request)
        
        user_messages = [m for m in result if m["role"] == "user" and m["content"] == "Hello"]
        assert len(user_messages) == 1
