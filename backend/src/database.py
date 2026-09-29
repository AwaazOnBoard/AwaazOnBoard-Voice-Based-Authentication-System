import os
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker, declarative_base
from sqlalchemy.exc import OperationalError
from sqlalchemy.pool import StaticPool
from dotenv import load_dotenv

load_dotenv()

# ── Default database URL ─────────────────────────────────────────
POSTGRES_URL = os.getenv(
    "DATABASE_URL",
    "postgresql://admin:secret@localhost:5432/awaazonboard",
)

# ── Base class for ORM models ────────────────────────────────────
Base = declarative_base()

# ── Engine initialisation with automatic fallback ────────────────
_using_sqlite = False

try:
    engine = create_engine(POSTGRES_URL)
    # Probe the connection – will raise OperationalError if Postgres is down
    with engine.connect() as _conn:
        pass
    print("✅ Connected to PostgreSQL.")
except (OperationalError, Exception) as exc:
    print("⚠️  PostgreSQL unreachable. Falling back to in-memory SQLite demo.")
    print(f"    Reason: {exc.__class__.__name__}: {exc}")
    engine = create_engine(
        "sqlite:///:memory:",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,                       # all threads share one connection
    )
    _using_sqlite = True

# ── Session factory ──────────────────────────────────────────────
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)


# Dependency to get the DB session in our FastAPI routes
def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
