"""
Pytest configuration and fixtures for the AI Chat backend.
"""
import os
import pytest
from pathlib import Path
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker, Session

from main import Base, get_db, get_db_factory, app, _get_or_create_default_user
from fastapi.testclient import TestClient

# Credentials used by the authenticated `client` fixture.
TEST_EMAIL = "tester@example.com"
TEST_PASSWORD = "test-password-123"


@pytest.fixture(scope="session")
def test_db_engine():
    """Create an in-memory SQLite database for testing."""
    # Use in-memory SQLite for fast isolated tests
    database_url = "sqlite:///:memory:"
    engine = create_engine(
        database_url,
        connect_args={"check_same_thread": False},
        echo=False,
    )
    # Create all tables
    Base.metadata.create_all(bind=engine)
    yield engine
    Base.metadata.drop_all(bind=engine)


@pytest.fixture
def test_db(test_db_engine):
    """Create a new database session for each test."""
    connection = test_db_engine.connect()
    transaction = connection.begin()
    session = sessionmaker(bind=connection, expire_on_commit=False)(bind=connection)
    
    yield session
    
    session.close()
    transaction.rollback()
    connection.close()


@pytest.fixture
def anon_client(test_db):
    """FastAPI test client with no Authorization header."""
    def override_get_db():
        yield test_db

    def override_db_factory():
        """Mimic main.SessionLocal, but on the test connection/transaction."""
        return sessionmaker(bind=test_db.get_bind(), expire_on_commit=False)

    app.dependency_overrides[get_db] = override_get_db
    app.dependency_overrides[get_db_factory] = override_db_factory

    with TestClient(app) as test_client:
        yield test_client

    app.dependency_overrides.clear()


@pytest.fixture
def client(anon_client):
    """
    Test client signed in as a freshly registered user.

    Every request carries that user's bearer token, so protected endpoints
    behave as they would for a logged-in app.
    """
    res = anon_client.post(
        "/auth/register",
        json={"email": TEST_EMAIL, "password": TEST_PASSWORD},
    )
    assert res.status_code == 201, res.text
    anon_client.headers["Authorization"] = f"Bearer {res.json()['access_token']}"
    return anon_client


@pytest.fixture
def default_user(test_db):
    """Create and return a default user for testing."""
    return _get_or_create_default_user(test_db)
