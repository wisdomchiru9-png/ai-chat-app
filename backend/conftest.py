"""
Pytest configuration and fixtures for the AI Chat backend.
"""
import os
import pytest
from pathlib import Path
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker, Session

from main import Base, get_db, app, _get_or_create_default_user
from fastapi.testclient import TestClient


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
def client(test_db):
    """Provide a FastAPI test client with dependency injection."""
    def override_get_db():
        yield test_db
    
    app.dependency_overrides[get_db] = override_get_db
    
    with TestClient(app) as test_client:
        yield test_client
    
    app.dependency_overrides.clear()


@pytest.fixture
def default_user(test_db):
    """Create and return a default user for testing."""
    return _get_or_create_default_user(test_db)
