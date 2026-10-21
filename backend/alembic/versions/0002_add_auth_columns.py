"""Add email + password_hash to users for JWT auth

Revision ID: 0002_add_auth_columns
Revises: 0001_initial
Create Date: 2026-10-21 00:00:00.000000
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = "0002_add_auth_columns"
down_revision: Union[str, None] = "0001_initial"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # Nullable so existing rows (e.g. the legacy "default_user") stay valid:
    # a user without an email can never log in, but their history is preserved.
    # batch_alter_table keeps this working on SQLite, which cannot ALTER ADD
    # a UNIQUE column directly.
    with op.batch_alter_table("users", schema=None) as batch_op:
        batch_op.add_column(sa.Column("email", sa.String(length=255), nullable=True))
        batch_op.add_column(sa.Column("password_hash", sa.String(length=255), nullable=True))
        batch_op.create_index(batch_op.f("ix_users_email"), ["email"], unique=True)


def downgrade() -> None:
    with op.batch_alter_table("users", schema=None) as batch_op:
        batch_op.drop_index(batch_op.f("ix_users_email"))
        batch_op.drop_column("password_hash")
        batch_op.drop_column("email")
