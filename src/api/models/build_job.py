from sqlalchemy import Column, Integer, String, DateTime, Text, create_engine
from sqlalchemy.ext.declarative import declarative_base
from sqlalchemy.orm import sessionmaker
import datetime
import os

Base = declarative_base()

class BuildJob(Base):
    __tablename__ = "build_jobs"

    id = Column(Integer, primary_key=True)
    build_id = Column(String(36), unique=True, nullable=False, index=True)
    service = Column(String(100), nullable=False)
    git_ref = Column(String(200), nullable=False)
    status = Column(String(20), default="queued")  # queued, building, success, failed, cancelled
    logs = Column(Text)
    created_at = Column(DateTime, default=datetime.datetime.utcnow)
    started_at = Column(DateTime)
    completed_at = Column(DateTime)
    machine = Column(String(100))
    worker_id = Column(String(100))
    error = Column(Text)
    images = Column(Text)  # JSON array as text
    architectures = Column(String(200))  # Comma-separated
    priority = Column(String(20))

    MAX_LOG_SIZE = 10 * 1024 * 1024  # 10MB

    def append_log(self, text: str):
        """Append text to logs with size limit"""
        current = self.logs or ""
        new_logs = current + text + "\n"

        # Truncate if too large
        if len(new_logs) > self.MAX_LOG_SIZE:
            new_logs = new_logs[-self.MAX_LOG_SIZE:]
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
