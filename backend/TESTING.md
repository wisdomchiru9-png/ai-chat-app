# Testing Guide — AI Chat Backend

## Overview

The test suite provides comprehensive coverage for the AI Chat backend:
- **test_api.py** — HTTP API endpoints and integration tests
- **test_models.py** — Database models and business logic

## Quick Start

### 1. Install dependencies

```bash
cd backend
pip install -r requirements.txt
```

### 2. Run all tests

```bash
pytest
```

### 3. Run specific test file

```bash
pytest tests/test_api.py
```

### 4. Run specific test class

```bash
pytest tests/test_api.py::TestHealthCheck
```

### 5. Run specific test

```bash
pytest tests/test_api.py::TestHealthCheck::test_root_endpoint
```

## Test Options

### Verbose output

```bash
pytest -v
```

### Show print statements

```bash
pytest -s
```

### Stop on first failure

```bash
pytest -x
```

### Run only failed tests from last run

```bash
pytest --lf
```

### Generate coverage report

```bash
pip install pytest-cov
pytest --cov=. --cov-report=html
# Open htmlcov/index.html in browser
```

### Run tests matching a pattern

```bash
pytest -k "session"  # Runs all tests with "session" in the name
```

## Test Structure

### Test API Endpoints (`test_api.py`)

**TestHealthCheck**
- `test_root_endpoint` — Verify health check returns service info

**TestSentimentAnalysis**
- `test_positive_sentiment` — Sentiment detection for positive text
- `test_negative_sentiment` — Sentiment detection for negative text
- `test_neutral_sentiment` — Sentiment on neutral text
- `test_sentiment_empty_message` — Validation of empty input

**TestChatEndpoint**
- `test_chat_without_session` — Chat without persisting to DB
- `test_chat_with_valid_history` — Multi-turn with explicit history
- `test_chat_with_invalid_history_role` — Input validation
- `test_chat_message_too_long` — Max length validation
- `test_chat_with_nonexistent_session` — Error handling

**TestSessionManagement**
- `test_create_session` — Create session with title
- `test_create_session_without_title` — Default title handling
- `test_list_sessions_empty` — List from empty DB
- `test_list_sessions_with_data` — List multiple sessions
- `test_list_sessions_with_limit` — Pagination
- `test_list_sessions_ordering` — Most-recent-first ordering
- `test_get_session_detail` — Retrieve session + messages
- `test_get_nonexistent_session` — 404 handling
- `test_update_session_title` — Rename session
- `test_update_session_invalid_title` — Validation
- `test_delete_session` — Delete + cascade
- `test_delete_nonexistent_session` — Error handling

**TestChatWithPersistence**
- `test_chat_creates_messages_in_session` — Message persistence
- `test_chat_uses_session_history` — History loading from DB
- `test_chat_auto_titles_session` — Auto-title on first message

**TestMessageDetails**
- `test_get_session_messages` — List messages with metadata
- `test_messages_include_sentiment` — Sentiment in response
- `test_messages_include_llm_metadata` — Provider/model info

**TestInputValidation**
- `test_chat_message_required` — Require message field
- `test_session_title_max_length` — Title truncation
- `test_invalid_json` — Malformed JSON handling

**TestConcurrency**
- `test_multiple_sessions_independent` — Session isolation

### Test Models & Logic (`test_models.py`)

**TestUserModel**
- `test_create_user` — Create with auto-generated ID
- `test_user_unique_constraint` — Uniqueness enforcement
- `test_user_sessions_relationship` — FK relationship

**TestChatSessionModel**
- `test_create_session` — Session creation
- `test_session_has_messages_relationship` — Message FK
- `test_session_cascade_delete_messages` — Cascade delete

**TestChatMessageModel**
- `test_create_message` — Full message creation
- `test_message_optional_fields` — Optional metadata

**TestSentimentClassification**
- `test_classify_positive_sentiment` — POSITIVE label
- `test_classify_negative_sentiment` — NEGATIVE label
- `test_classify_empty_text` — Empty input handling
- `test_sentiment_confidence_range` — Confidence bounds

**TestHistoryNormalization**
- `test_normalize_list_of_dicts` — Message list normalization
- `test_normalize_consecutive_roles` — Message merging
- `test_normalize_invalid_roles` — Invalid role filtering
- `test_normalize_empty_history` — Empty input handling

**TestContextWindowTrimming**
- `test_trim_respects_max_chars` — Context limit enforcement
- `test_trim_keeps_system_message` — Preserve system prompt
- `test_trim_empty_history` — Empty input handling
- `test_trim_preserves_message_order` — Chronological order

**TestBuildMessagesForLLM**
- `test_build_with_explicit_history` — Explicit history priority
- `test_build_with_db_history` — DB history fallback
- `test_build_adds_system_prompt` — System prompt insertion
- `test_build_avoids_duplicate_user_message` — Deduplication

## Fixtures

All tests use fixtures defined in `conftest.py`:

- **`test_db_engine`** — SQLite in-memory DB for fast tests
- **`test_db`** — Fresh DB session per test (auto-rollback)
- **`client`** — FastAPI TestClient with dependency injection
- **`default_user`** — Pre-created default user for tests

## Coverage Goals

- **API Endpoints** — 90%+ coverage
- **Database Models** — 100% coverage
- **Business Logic** — 85%+ coverage

Current coverage can be checked with:

```bash
pytest --cov=. --cov-report=term-missing
```

## Continuous Integration

Tests should run on:
1. **Local machine** — Before committing
2. **CI/CD pipeline** — On every PR/push
3. **Docker build** — During container build (optional)

Add to `.github/workflows/test.yml` for GitHub Actions:

```yaml
name: Tests
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - uses: actions/setup-python@v4
        with:
          python-version: '3.11'
      - run: pip install -r backend/requirements.txt
      - run: pytest backend/
```

## Troubleshooting

### Tests fail with "No module named 'main'"

Make sure you're running pytest from the `backend/` directory:

```bash
cd backend
pytest
```

### Tests hang or timeout

- Check for infinite loops or blocking operations
- Use `pytest --timeout=30` to set test timeout
- Use `-x` flag to stop on first failure

### Database errors

- Tests use in-memory SQLite, ensure no file conflicts
- Check that `conftest.py` fixtures are not misconfigured
- Verify SQLAlchemy version matches requirements.txt

### Module import errors

- Ensure Python path includes current directory:
  ```bash
  export PYTHONPATH="${PYTHONPATH}:$(pwd)"
  ```

## Best Practices

1. **Run tests before committing**
   ```bash
   pytest && git commit
   ```

2. **Add tests for new features**
   - Write test first (TDD)
   - Implement feature
   - Verify test passes

3. **Keep tests isolated**
   - Use fixtures for setup
   - Don't depend on test execution order
   - Clean up after tests

4. **Use descriptive names**
   ```python
   def test_chat_should_persist_messages_to_session():  # Good
   def test_chat():  # Poor
   ```

5. **Test edge cases**
   - Empty inputs
   - Maximum lengths
   - Invalid types
   - Concurrent operations

## Performance

Typical test suite metrics:
- **Total tests**: 65+
- **Execution time**: ~5-10 seconds
- **Memory usage**: ~200MB

## Further Reading

- [Pytest Documentation](https://docs.pytest.org/)
- [FastAPI Testing](https://fastapi.tiangolo.com/advanced/testing-dependencies/)
- [SQLAlchemy Testing](https://docs.sqlalchemy.org/en/20/faq/testing.html)
