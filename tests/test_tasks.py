import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.main import app
from app.database import Base, get_db

# In-memory SQLite DB for isolated unit tests
SQLITE_URL = "sqlite:///:memory:"

engine = create_engine(
    SQLITE_URL,
    connect_args={"check_same_thread": False},
    poolclass=StaticPool,
)
TestingSession = sessionmaker(autocommit=False, autoflush=False, bind=engine)


def override_get_db():
    db = TestingSession()
    try:
        yield db
    finally:
        db.close()


@pytest.fixture(autouse=True)
def setup_db():
    Base.metadata.create_all(bind=engine)
    yield
    Base.metadata.drop_all(bind=engine)


app.dependency_overrides[get_db] = override_get_db
client = TestClient(app)


def test_create_task():
    resp = client.post("/tasks/", json={"title": "Test task", "description": "desc"})
    assert resp.status_code == 201
    data = resp.json()
    assert data["title"] == "Test task"
    assert data["completed"] is False


def test_list_tasks():
    client.post("/tasks/", json={"title": "Task A"})
    client.post("/tasks/", json={"title": "Task B"})
    resp = client.get("/tasks/")
    assert resp.status_code == 200
    assert len(resp.json()) == 2


def test_get_task():
    created = client.post("/tasks/", json={"title": "My Task"}).json()
    resp = client.get(f"/tasks/{created['id']}")
    assert resp.status_code == 200
    assert resp.json()["title"] == "My Task"


def test_get_task_not_found():
    resp = client.get("/tasks/9999")
    assert resp.status_code == 404


def test_update_task():
    created = client.post("/tasks/", json={"title": "Old Title"}).json()
    resp = client.put(f"/tasks/{created['id']}", json={"title": "New Title", "completed": True})
    assert resp.status_code == 200
    assert resp.json()["title"] == "New Title"
    assert resp.json()["completed"] is True


def test_delete_task():
    created = client.post("/tasks/", json={"title": "Delete Me"}).json()
    resp = client.delete(f"/tasks/{created['id']}")
    assert resp.status_code == 204
    resp = client.get(f"/tasks/{created['id']}")
    assert resp.status_code == 404


def test_health_endpoint():
    resp = client.get("/health")
    assert resp.status_code == 200
    assert "status" in resp.json()
