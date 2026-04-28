"""
ResilientNet Backend — FastAPI application.

Exposes 3 endpoints:
    POST /predict_cascade   → cascade engine
    POST /parse_news        → Gemini news parser
    POST /optimize_routes   → route optimizer

Plus health/debug:
    GET  /                  → status
    GET  /hubs              → list all hubs (debug)
    GET  /shipments         → list sample shipments (debug)

Run locally:
    uvicorn app.main:app --reload --port 8080

Interactive docs:
    http://localhost:8080/docs
"""

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware

from .models import (
    DisruptionEvent, CascadeResult, AffectedShipment,
    NewsItem, ParsedDisruption,
    OptimizeRequest, OptimizeResult, Reroute,
    HealthStatus,
)
from .cascade_engine import predict_cascade
from .gemini_client import parse_news_headline, GEMINI_AVAILABLE
from .route_optimizer import optimize_routes
from .data_loader import HUBS_LIST, SHIPMENTS_LIST
from .gnn_cascade import predict_cascade_gnn, get_status as get_gnn_status
from .realtime_routes import realtime_router
from .realtime_poller import start_poller


# ============================================================
# APP SETUP
# ============================================================

app = FastAPI(
    title="ResilientNet Backend",
    description="Supply chain cascade prediction + Gemini-powered disruption analysis + Real-time Firebase polling",
    version="0.3.0",
)

# Register real-time routes (/realtime/events, /realtime/simulate, etc.)
app.include_router(realtime_router)


@app.on_event("startup")
async def startup_event():
    """Start the background news poller when the server boots."""
    import os
    if os.environ.get("DISABLE_POLLER", "").lower() not in ("1", "true", "yes"):
        start_poller()
    else:
        print("[STARTUP] Poller disabled via DISABLE_POLLER env var")

# CORS — allow Flutter web + Cloud Functions to call us
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # allows Flutter web on any localhost port
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# ============================================================
# HEALTH / STATUS
# ============================================================

@app.get("/", response_model=HealthStatus)
def root():
    """Health check — useful for confirming deployment worked."""
    gnn_status = get_gnn_status()
    return HealthStatus(
        status="online",
        hubs_loaded=len(HUBS_LIST),
        shipments_loaded=len(SHIPMENTS_LIST),
        gemini_configured=GEMINI_AVAILABLE,
        version="0.3.0",
    )


@app.get("/gnn_status")
def gnn_status():
    """Detailed GNN status — available, model path, load errors."""
    return get_gnn_status()


# ============================================================
# ENDPOINT 1 — CASCADE PREDICTION (the core brain)
# ============================================================

@app.post("/predict_cascade", response_model=CascadeResult)
def predict_cascade_endpoint(event: DisruptionEvent):
    """
    Given a disruption at a specific hub, return the list of affected
    shipments and their cascade risk scores.

    Example:
        POST /predict_cascade
        {
          "hub_id": "HUB-00",
          "severity": 0.9,
          "event_type": "cyclone"
        }
    """
    affected_raw, affected_hubs, confidence = predict_cascade(
        disrupted_hub_id=event.hub_id,
        severity=event.severity,
        max_depth=event.max_depth,
    )

    if event.hub_id not in [h["id"] for h in HUBS_LIST]:
        raise HTTPException(
            status_code=404,
            detail=f"Hub '{event.hub_id}' not found. Valid IDs: HUB-00 through HUB-14",
        )

    # Convert dicts to typed AffectedShipment models
    affected = [AffectedShipment(**s) for s in affected_raw]

    return CascadeResult(
        disruption=event,
        affected_shipments=affected,
        total_at_risk=len(affected),
        affected_hubs=affected_hubs,
        confidence=confidence,
    )


# ============================================================
# ENDPOINT 1B — GNN CASCADE PREDICTION (trained ST-GCN)
# ============================================================

@app.post("/predict_cascade_gnn")
def predict_cascade_gnn_endpoint(event: DisruptionEvent):
    """
    Alternative cascade prediction using the trained ST-GCN model.
    Runs a real graph neural network (validation MAE 0.033).

    Uses the South India hub graph (20 nodes) — different from the
    hand-crafted engine which uses the international 15-hub graph.

    If the GNN isn't available (missing torch or model file), returns
    a 503 so the caller can fall back to /predict_cascade.

    Example:
        POST /predict_cascade_gnn
        {
          "hub_id": "Kochi Port",
          "severity": 0.9,
          "event_type": "cyclone"
        }

    Accepts hub_id as either a number ("0"), exact name ("Kochi Port"),
    or partial match ("Kochi").
    """
    result = predict_cascade_gnn(
        disrupted_hub_name=event.hub_id,
        severity=event.severity,
    )

    if result is None:
        gnn_info = get_gnn_status()
        if not gnn_info["gnn_available"]:
            raise HTTPException(
                status_code=503,
                detail=f"GNN not available: {gnn_info.get('load_error', 'unknown')}. "
                       f"Fall back to /predict_cascade instead.",
            )
        raise HTTPException(
            status_code=404,
            detail=f"Hub '{event.hub_id}' not found in GNN graph. "
                   f"Try: Kochi Port, Chennai Port, Bengaluru Warehouse, etc.",
        )

    return result


# ============================================================
# ENDPOINT 2 — NEWS PARSING (Gemini)
# ============================================================

@app.post("/parse_news", response_model=ParsedDisruption)
def parse_news_endpoint(item: NewsItem):
    """
    Send a news headline to Gemini and get back a structured disruption event.
    Use the output as input to /predict_cascade for the full demo flow.

    Example:
        POST /parse_news
        {
          "headline": "Houthi drone strike closes Red Sea shipping lane"
        }
    """
    result = parse_news_headline(item.headline)
    return ParsedDisruption(**result)


# ============================================================
# ENDPOINT 3 — ROUTE OPTIMIZATION
# ============================================================

@app.post("/optimize_routes", response_model=OptimizeResult)
def optimize_routes_endpoint(request: OptimizeRequest):
    """
    For each affected shipment, return an alternative route avoiding
    the blocked hubs.

    Example:
        POST /optimize_routes
        {
          "affected_shipment_ids": ["SHP-0042", "SHP-0118"],
          "blocked_hub_ids": ["HUB-00"]
        }
    """
    reroute_dicts = optimize_routes(
        affected_shipment_ids=request.affected_shipment_ids,
        blocked_hub_ids=request.blocked_hub_ids,
    )
    reroutes = [Reroute(**r) for r in reroute_dicts]
    total_savings = sum(r.savings_inr for r in reroutes)

    return OptimizeResult(
        reroutes=reroutes,
        count=len(reroutes),
        total_savings_inr=total_savings,
    )


# ============================================================
# DEBUG ENDPOINTS — useful during development
# ============================================================

@app.get("/hubs")
def list_hubs():
    """List all hubs — useful for checking data loaded correctly."""
    return {"count": len(HUBS_LIST), "hubs": HUBS_LIST}


@app.get("/shipments")
def list_shipments(limit: int = 10):
    """List sample shipments — useful for checking data."""
    return {
        "total": len(SHIPMENTS_LIST),
        "returned": min(limit, len(SHIPMENTS_LIST)),
        "shipments": SHIPMENTS_LIST[:limit],
    }