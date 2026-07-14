from fastapi import FastAPI
from app.database import check_db_connection
from app.schemas import HealthResponse
from app.routers import tasks

app = FastAPI(title="Task Manager CRUD API", version="1.0.0")

app.include_router(tasks.router)


@app.get("/health", response_model=HealthResponse)
def health_check():
    db_ok = check_db_connection()
    return HealthResponse(
        status="healthy" if db_ok else "unhealthy",
        app="ok",
        database="ok" if db_ok else "unreachable",
    )


@app.get("/")
def root():
    return {"message": "Task Manager API", "docs": "/docs", "health": "/health"}
