"""
realtime_routes.py — FastAPI routes for the real-time Firebase integration.

Add to main.py with:
    from .realtime_routes import realtime_router
    app.include_router(realtime_router)

New endpoints:
    GET  /realtime/events           → recent disruptions (from Firestore or memory)
    GET  /realtime/status           → poller health + last poll time
    POST /realtime/simulate         → inject any headline with custom severity (DEMO TOOL)
    POST /realtime/poll_now         → trigger immediate poll cycle (admin)
"""

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field
from typing import Optional
import datetime

realtime_router = APIRouter(prefix="/realtime", tags=["realtime"])


# ── Request/response models ────────────────────────────────────────────────────

class SimulateRequest(BaseModel):
    """
    Inject a custom headline into the pipeline for demo purposes.
    Great for impressing judges without waiting for a real disruption.
    """
    headline: str = Field(..., min_length=10, description="News headline to simulate")
    severity_override: Optional[float] = Field(
        None, ge=0.0, le=1.0,
        description="Override Gemini's severity (0.0-1.0). Leave null to let Gemini decide."
    )
    location_override: Optional[str] = Field(
        None, description="Override location for GNN routing. E.g. 'Chennai Port'"
    )
    write_to_firebase: bool = Field(
        True, description="Whether to push this to Firestore (Flutter will see it live)"
    )


class SimulateResponse(BaseModel):
    success: bool
    event_id: str
    gemini_analysis: dict
    cascade_result: Optional[dict]
    routes_found: int
    firebase_written: bool
    message: str


# ── GET /realtime/events ───────────────────────────────────────────────────────

@realtime_router.get("/events")
def get_realtime_events(limit: int = 20, severity_min: float = 0.0):
    """
    Returns recent disruption events detected by the background poller.

    If Firebase is configured, queries Firestore directly.
    Otherwise returns from the in-memory buffer (still works for demo).
    """
    from .realtime_poller import get_recent_events, _firebase_ok, _db

    if _firebase_ok and _db:
        try:
            query = (
                _db.collection("disruptions")
                .where("severity", ">=", severity_min)
                .order_by("severity", direction="DESCENDING")
                .order_by("created_at", direction="DESCENDING")
                .limit(limit)
            )
            docs = query.stream()
            events = []
            for doc in docs:
                data = doc.to_dict()
                # Convert Firestore timestamps to ISO strings for JSON
                for field in ["created_at", "updated_at"]:
                    if field in data and hasattr(data[field], "isoformat"):
                        data[field] = data[field].isoformat()
                events.append(data)
            return {
                "source": "firestore",
                "count": len(events),
                "events": events,
            }
        except Exception as e:
            print(f"[REALTIME] Firestore query failed, falling back to memory: {e}")

    # Fallback: in-memory buffer
    events = get_recent_events(limit)
    return {
        "source": "memory",
        "count": len(events),
        "events": events,
    }


# ── GET /realtime/status ───────────────────────────────────────────────────────

@realtime_router.get("/status")
def get_realtime_status():
    """Poller health check — is it running? When did it last poll? Firebase OK?"""
    from .realtime_poller import _poller_thread, _running, _firebase_ok, _seen_hashes

    return {
        "poller_running": _running and bool(_poller_thread and _poller_thread.is_alive()),
        "firebase_connected": _firebase_ok,
        "deduplicated_articles": len(_seen_hashes),
        "timestamp": datetime.datetime.utcnow().isoformat(),
    }


# ── POST /realtime/simulate ────────────────────────────────────────────────────

@realtime_router.post("/simulate", response_model=SimulateResponse)
def simulate_disruption(req: SimulateRequest):
    """
    THE DEMO ENDPOINT — inject any headline and watch Flutter update live.

    This runs the full pipeline (Gemini → GNN → Optimizer → Firebase)
    on a headline you provide, so you can demo specific scenarios without
    waiting for real news. Perfect for judging panels.

    Example:
        POST /realtime/simulate
        {
          "headline": "Severe flooding shuts Chennai-Bangalore NH-48 near Ranipet",
          "severity_override": 0.85,
          "location_override": "Chennai Port"
        }
    """
    import hashlib

    # ── Step 1: Gemini analysis ────────────────────────────────────────────────
    try:
        from .gemini_client import parse_news_headline
        gemini = parse_news_headline(req.headline)
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Gemini failed: {e}")

    # Apply overrides
    if req.severity_override is not None:
        gemini["severity"] = req.severity_override
    if req.location_override:
        gemini["location"] = req.location_override
    gemini["headline"] = req.headline
    gemini["source"] = "Simulated (Demo)"
    gemini["published_at"] = datetime.datetime.utcnow().isoformat()

    # ── Step 2: GNN cascade ────────────────────────────────────────────────────
    cascade = None
    try:
        from .gnn_cascade import predict_cascade_gnn
        location = gemini.get("location") or "Chennai Port"
        cascade = predict_cascade_gnn(
            disrupted_hub_name=location,
            severity=gemini.get("severity", 0.5),
        )
    except Exception as e:
        print(f"[SIMULATE] GNN failed (non-fatal): {e}")

    # ── Step 3: Route optimization ─────────────────────────────────────────────
    routes = []
    try:
        from .route_optimizer import optimize_routes
        if cascade:
            affected_ids = [s["shipment_id"] for s in cascade.get("affected_shipments", [])[:10]]
            blocked = [cascade.get("disrupted_hub", "")]
            if affected_ids:
                routes = optimize_routes(
                    affected_shipment_ids=affected_ids,
                    blocked_hub_ids=[h for h in blocked if h],
                )
    except Exception as e:
        print(f"[SIMULATE] Optimizer failed (non-fatal): {e}")

    # ── Step 4: Write to Firebase ──────────────────────────────────────────────
    firebase_written = False
    event_id = hashlib.md5(req.headline.encode()).hexdigest()

    if req.write_to_firebase:
        try:
            from .realtime_poller import _write_to_firestore, _firebase_ok
            fake_article = {
                "_hash": event_id,
                "title": req.headline,
                "description": "",
                "publishedAt": datetime.datetime.utcnow().isoformat(),
                "source": {"name": "Simulated"},
            }
            _write_to_firestore(fake_article, gemini, cascade, routes)
            firebase_written = _firebase_ok
        except Exception as e:
            print(f"[SIMULATE] Firebase write failed (non-fatal): {e}")

    severity = gemini.get("severity", 0)
    sev_label = "CRITICAL" if severity >= 0.8 else "HIGH" if severity >= 0.6 else "MEDIUM" if severity >= 0.4 else "LOW"

    return SimulateResponse(
        success=True,
        event_id=event_id,
        gemini_analysis=gemini,
        cascade_result=cascade,
        routes_found=len(routes),
        firebase_written=firebase_written,
        message=f"[{sev_label}] Disruption simulated. "
                f"{'Flutter updated live via Firebase.' if firebase_written else 'Firebase not configured — check /realtime/events for result.'}",
    )


# ── POST /realtime/poll_now ────────────────────────────────────────────────────

@realtime_router.post("/poll_now")
def trigger_poll_now():
    """
    Trigger an immediate poll cycle without waiting for the interval.
    Useful for demos or admin control.
    """
    import threading
    from .realtime_poller import _poll_once

    def _run():
        try:
            _poll_once()
        except Exception as e:
            print(f"[POLL_NOW] Error: {e}")

    t = threading.Thread(target=_run, daemon=True)
    t.start()

    return {
        "message": "Poll triggered — check /realtime/events in ~10 seconds",
        "timestamp": datetime.datetime.utcnow().isoformat(),
    }