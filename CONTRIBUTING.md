# Contributing to AI Chat App

Thank you for your interest in contributing! This guide will help you understand the project structure and how to make effective contributions.

## Code of Conduct

- Be respectful and inclusive
- Provide constructive feedback
- Help others learn and grow

## Getting Started

### 1. Fork & Clone

```bash
git clone https://github.com/YOUR_USERNAME/ai-chat-app.git
cd ai-chat-app
```

### 2. Set Up Development Environment

```bash
# Backend
cd backend
python -m venv venv
source venv/bin/activate  # On Windows: venv\Scripts\activate
pip install -r requirements.txt

# Evaluator service
cd ../evaluator-service
npm install

# Flutter app
cd ../flutter_app
flutter pub get
```

### 3. Verify Setup

```bash
# Test backend
cd backend
pytest -v

# Test evaluator
cd ../evaluator-service
npm test

# Test Flutter build
cd ../flutter_app
flutter analyze
```

## Development Workflow

### Before Starting Work

1. **Create a branch** for your feature/fix:
   ```bash
   git checkout -b feature/my-feature
   # or
   git checkout -b fix/my-bug
   ```

2. **Keep main updated**:
   ```bash
   git fetch origin
   git rebase origin/main
   ```

### While Coding

1. **Write tests first** (TDD)
   ```bash
   # Example: Add test in backend/tests/
   def test_my_new_feature():
       # Arrange
       # Act
       # Assert
   ```

2. **Run tests frequently**
   ```bash
   cd backend
   pytest -v
   ```

3. **Check code quality**
   ```bash
   cd backend
   # Formatting
   black .
   
   # Linting
   flake8 . --count
   
   # Type hints
   mypy main.py --ignore-missing-imports
   ```

4. **Keep commits clean**
   ```bash
   git add .
   git commit -m "feat: add new chat feature"
   git commit -m "test: add tests for new feature"
   ```

### Commit Message Format

Follow [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <subject>

<body>

<footer>
```

Types:
- `feat` — New feature
- `fix` — Bug fix
- `test` — Adding/updating tests
- `docs` — Documentation
- `chore` — Maintenance, dependencies
- `refactor` — Code improvement without behavior change

Examples:
```
feat(backend): add streaming responses to /chat endpoint
fix(flutter): handle network errors gracefully
test(api): add 20+ integration tests for sessions
docs(backend): improve TESTING.md with examples
```

### Testing Requirements

Every PR must pass:

```bash
cd backend
pytest -v --tb=short
pytest --cov=. --cov-report=term-missing
```

**Test coverage targets:**
- API endpoints: 85%+
- Models: 100%
- Business logic: 80%+

See [TESTING.md](backend/TESTING.md) for detailed guide.

## Pull Request Process

### Before Submitting

1. **Run full test suite**
   ```bash
   cd backend
   pytest
   ```

2. **Check for linting issues**
   ```bash
   cd backend
   black . --check
   flake8 .
   ```

3. **Update documentation**
   - README.md if user-facing changes
   - TESTING.md if test structure changes
   - Add docstrings to new functions

4. **Update CHANGELOG** (if maintaining one)

### Creating the PR

1. **Push your branch**
   ```bash
   git push origin feature/my-feature
   ```

2. **Create PR on GitHub**
   - Use descriptive title
   - Reference issues with `Closes #123`
   - Describe what changed and why
   - Link related PRs/issues

3. **Template**:
   ```markdown
   ## Description
   Brief description of changes.
   
   Fixes #(issue)
   
   ## Type of Change
   - [ ] Bug fix
   - [ ] New feature
   - [ ] Breaking change
   - [ ] Documentation
   
   ## Testing
   - [ ] Added tests
   - [ ] All tests pass
   - [ ] Coverage maintained
   
   ## Screenshots (if UI change)
   Before/after screenshots
   ```

### After Submission

- Respond to review comments promptly
- Make requested changes in new commits (don't squash until approved)
- Re-request review after changes
- Be patient — maintainers are busy!

## Code Style Guide

### Python (Backend)

```python
# Type hints required
def classify_sentiment(text: str) -> tuple[str, float]:
    """Classify sentiment of text.
    
    Args:
        text: Input text to classify.
    
    Returns:
        Tuple of (label, confidence).
    
    Raises:
        ValueError: If text is empty.
    """
    if not text:
        raise ValueError("Text cannot be empty")
    # Implementation
```

- Use f-strings: `f"Hello {name}"`
- Max line length: 100 chars
- Format with `black`
- Type check with `mypy`

### JavaScript (Evaluator)

```javascript
/**
 * Evaluate LLM provider performance.
 * @param {Object} config - Configuration
 * @returns {Promise<Object>} Evaluation results
 */
async function evaluateProvider(config) {
  // Implementation
}
```

- Use async/await
- Prefer const/let over var
- Add JSDoc comments
- Use semicolons

### Dart (Flutter)

```dart
/// Calculate sentiment score.
/// 
/// Returns a score between -1.0 (negative) and 1.0 (positive).
double calculateSentiment(String text) {
  // Implementation
}
```

- Use meaningful variable names
- Add doc comments for public APIs
- Follow Flutter style guide

## Common Tasks

### Adding a New API Endpoint

1. **Add to main.py**:
   ```python
   @app.post("/my-endpoint", response_model=MyResponse)
   def my_endpoint(request: MyRequest, db: SASession = Depends(get_db)):
       # Implementation
   ```

2. **Add request/response models**:
   ```python
   class MyRequest(BaseModel):
       field: str = Field(..., description="Field description")
   
   class MyResponse(BaseModel):
       result: str
   ```

3. **Add to tests/test_api.py**:
   ```python
   def test_my_endpoint(self, client):
       response = client.post("/my-endpoint", json={"field": "value"})
       assert response.status_code == 200
   ```

### Adding a Database Migration

```bash
cd backend

# Create migration
alembic revision --autogenerate -m "Add my_column to users"

# Review generated migration in alembic/versions/

# Apply locally
alembic upgrade head

# Test with pytest (automatic)
```

### Adding a New LLM Provider

1. **Extend BaseLLM**:
   ```python
   class MyLLM(BaseLLM):
       name = "my_provider"
       
       def _post_init(self):
           # Initialize provider
       
       def generate(self, messages: list[dict]) -> str:
           # Implement chat completion
   ```

2. **Add to provider map**:
   ```python
   _PROVIDER_MAP["my_provider"] = MyLLM
   ```

3. **Add tests**:
   ```python
   def test_my_llm_generate():
       llm = MyLLM()
       reply = llm.generate([{"role": "user", "content": "Hello"}])
       assert len(reply) > 0
   ```

### Adding Flutter UI Feature

1. **Create widget**:
   ```dart
   class MyWidget extends StatefulWidget {
     @override
     State<MyWidget> createState() => _MyWidgetState();
   }
   ```

2. **Add to main.dart**:
   ```dart
   Widget build(BuildContext context) {
     return MyWidget();
   }
   ```

3. **Test on devices**:
   ```bash
   flutter run -d all  # Run on all devices
   ```

## Troubleshooting

### Tests fail locally but pass on CI

- Check Python version matches CI (3.11+)
- Clear pytest cache: `pytest --cache-clear`
- Check for environment variables in .env

### Docker build fails

```bash
docker compose up --build --no-cache
```

### Flutter build issues

```bash
flutter clean
flutter pub get
flutter run
```

### Git conflicts on migrations

```bash
# Never manually merge migration files
git merge --abort
git fetch origin
git rebase origin/main
# Alembic will handle ordering
```

## Performance & Security

### Performance
- Profile slow endpoints: Use Python cProfile
- Cache expensive operations
- Paginate large result sets
- Optimize database queries

### Security
- Never commit API keys or secrets
- Use environment variables
- Validate all user input
- Use parameterized queries (SQLAlchemy)
- Keep dependencies updated

```bash
cd backend
pip-audit  # Check for vulnerabilities
```

## Documentation

Good documentation is crucial:

- **README.md** — Project overview & quick start
- **TESTING.md** — How to run & write tests
- **Code comments** — Why, not what
- **Docstrings** — Every function needs one
- **CONTRIBUTING.md** — This file!

## Getting Help

- **Issues** — Ask questions in GitHub Issues
- **Discussions** — Start discussions for ideas
- **Email** — Contact maintainers directly

## Review Process

1. **Automated checks**
   - Tests must pass
   - Coverage maintained
   - No security issues

2. **Human review**
   - Code quality
   - Architecture fit
   - Documentation

3. **Approval**
   - At least 1 approval required
   - Maintainer discretion

## License

By contributing, you agree your work is licensed under MIT License.

---

Thank you for contributing! 🎉
