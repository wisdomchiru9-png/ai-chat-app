from logging.config import fileConfig
import os
from pathlib import Path

from sqlalchemy import engine_from_config, pool
from alembic import context

# load .env so DATABASE_URL is picked up automatically
try:
    from dotenv import load_dotenv
    load_dotenv(Path(__file__).resolve().parent.parent / ".env")
except Exception:
    pass

# this is the Alembic Config object, which provides access to .ini values
config = context.config

# Interpret the config file for Python logging.
if config.config_file_name is not None:
    fileConfig(config.config_file_name)

# Import our model metadata for autogenerate support
from main import Base  # noqa: E402
target_metadata = Base.metadata

# Default to SQLite fallback (matches main.py) when no env is set
_default_db = f"sqlite:///{Path(__file__).resolve().parent.parent / 'ai_chat_app.db'}"
DATABASE_URL = os.getenv("DATABASE_URL", _default_db).strip()
config.set_main_option("sqlalchemy.url", DATABASE_URL)


def run_migrations_offline() -> None:
    """Run migrations in 'offline' mode."""
    url = config.get_main_option("sqlalchemy.url")
    context.configure(
        url=url,
        target_metadata=target_metadata,
        literal_binds=True,
        dialect_opts={"paramstyle": "named"},
        render_as_batch=True,
    )
    with context.begin_transaction():
        context.run_migrations()


def run_migrations_online() -> None:
    """Run migrations in 'online' mode."""
    connectable = engine_from_config(
        config.get_section(config.config_ini_section, {}),
        prefix="sqlalchemy.",
        poolclass=pool.NullPool,
    )
    with connectable.connect() as connection:
        context.configure(
            connection=connection,
            target_metadata=target_metadata,
            render_as_batch=True,
        )
        with context.begin_transaction():
            context.run_migrations()


if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
