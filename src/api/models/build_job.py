import datetime
import os
from typing import ClassVar

from sqlalchemy import DateTime, Integer, String, Text, create_engine
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, sessionmaker


def utcnow() -> datetime.datetime:
    """Naive UTC timestamp, byte-for-byte what ``datetime.utcnow()`` returned.

    ``utcnow()`` is deprecated in Python 3.12; ``now(UTC)`` is the supported
    replacement, and dropping the tzinfo keeps the naive values the SQLite
    columns have always stored.
    """
    return datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)


class Base(DeclarativeBase):
    pass


class BuildJob(Base):
    __tablename__ = "build_jobs"

    # The columns marked `nullable=True` were nullable in the original schema and
    # stay that way. The annotation is non-Optional because every writer in this
    # application supplies them (API-created rows and the queue loader both
    # require the value), but the DDL must not tighten a table that existing
    # on-disk databases already have, so nullability is spelled out explicitly.
    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    build_id: Mapped[str] = mapped_column(String(36), unique=True, nullable=False, index=True)
    service: Mapped[str] = mapped_column(String(100), nullable=False)
    git_ref: Mapped[str] = mapped_column(String(200), nullable=False)
    status: Mapped[str] = mapped_column(
        String(20), nullable=True, default="queued"
    )  # queued, building, success, failed, cancelled
    logs: Mapped[str | None] = mapped_column(Text)
    created_at: Mapped[datetime.datetime] = mapped_column(DateTime, nullable=True, default=utcnow)
    started_at: Mapped[datetime.datetime | None] = mapped_column(DateTime)
    completed_at: Mapped[datetime.datetime | None] = mapped_column(DateTime)
    machine: Mapped[str] = mapped_column(String(100), nullable=True)
    worker_id: Mapped[str | None] = mapped_column(String(100))
    error: Mapped[str | None] = mapped_column(Text)
    images: Mapped[str | None] = mapped_column(Text)  # JSON array as text
    architectures: Mapped[str] = mapped_column(String(200), nullable=True)  # Comma-separated
    priority: Mapped[str] = mapped_column(String(20), nullable=True)

    MAX_LOG_SIZE: ClassVar[int] = 10 * 1024 * 1024  # 10MB

    def append_log(self, text: str) -> None:
        """Append text to logs with size limit"""
        current = self.logs or ""
        new_logs = current + text + "\n"

        # Truncate if too large
        if len(new_logs) > self.MAX_LOG_SIZE:
            new_logs = new_logs[-self.MAX_LOG_SIZE :]
            new_logs = "[...truncated...]\n" + new_logs

        self.logs = new_logs


# Database setup
DATABASE_PATH = os.getenv("BUILD_DB_PATH", "/tmp/builds.db")
engine = create_engine(f"sqlite:///{DATABASE_PATH}", connect_args={"check_same_thread": False})
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)


def init_db():
    """Initialize database tables"""
    Base.metadata.create_all(bind=engine)


def get_db():
    """Get database session"""
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
