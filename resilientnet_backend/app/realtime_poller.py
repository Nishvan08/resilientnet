"""
realtime_poller.py — Proactive background loop for ResilientNet.

THE PROBLEM THIS SOLVES:
    The old system only ran when someone manually POST'd to /parse_news.
    This module runs autonomously — it polls NewsAPI every 5 minutes,
    finds real Indian logistics disruptions, runs the full Gemini + GNN
    + route optimizer pipeline, and pushes results to Firebase Firestore.
    Flutter gets the update in <1 second with no refresh needed.

DATA FLOW:
    NewsAPI polls every 5 min (real headlines)
        ↓
    realtime_poller.py runs Gemini + GNN cascade + route optimizer
        ↓
    Results written to Firebase Firestore
        ↓
    Flutter gets pushed the update in <1 second (StreamBuilder)
        ↓
    Driver gets FCM push notification on their phone

SETUP:
    1. pip install firebase-admin newsapi-python
    2. Set env vars: NEWS_API_KEY, FIREBASE_CREDS_PATH
    3. python -m app.realtime_poller        (run standalone)
       OR it auto-starts when you run main.py (background thread)
"""

import os
import json
import time
import hashlib
import threading
import datetime
import requests
from typing import Optional

from dotenv import load_dotenv
load_dotenv()

NEWS_API_KEY    = os.environ.get("NEWS_API_KEY", "").strip()
FIREBASE_CREDS  = os.environ.get("FIREBASE_CREDS_PATH", "serviceAccountKey.json")
POLL_INTERVAL   = int(os.environ.get("POLL_INTERVAL_SEC", "300"))   # 5 minutes

# ── Firebase (optional — degrades gracefully if creds not set) ─────────────────
_db = None
_firebase_ok = False

def _init_firebase():
    global _db, _firebase_ok
    try:
        import firebase_admin
        from firebase_admin import credentials, firestore
        if not firebase_admin._apps:
            cred = credentials.Certificate(FIREBASE_CREDS)
            firebase_admin.initialize_app(cred)
        _db = firestore.client()
        _firebase_ok = True
        print("[FIREBASE] ✅ Connected to Firestore")
    except Exception as e:
        print(f"[FIREBASE] ⚠️  Not connected ({e}) — results will only go to /realtime/events endpoint")
        _firebase_ok = False

# ── Indian logistics search queries ───────────────────────────────────────────
LOGISTICS_QUERIES = [
    "India shipping",
    "India port",
    "India logistics",
]

# ── Deduplication — keep in memory + Firestore ────────────────────────────────
_seen_hashes: set = set()

def _load_seen_hashes():
    """Load previously processed article hashes from Firestore."""
    if not _firebase_ok or _db is None:
        return
    try:
        from firebase_admin import firestore as fs
        docs = _db.collection("processed_hashes").limit(500).stream()
        for doc in docs:
            _seen_hashes.add(doc.id)
        print(f"[DEDUP] Loaded {len(_seen_hashes)} seen hashes")
    except Exception as e:
        print(f"[DEDUP] Could not load hashes: {e}")

def _mark_seen(h: str):
    _seen_hashes.add(h)
    if _firebase_ok and _db:
        try:
            from firebase_admin import firestore as fs
            _db.collection("processed_hashes").document(h).set(
                {"ts": fs.SERVER_TIMESTAMP}
            )
        except Exception:
            pass


# ── NewsAPI fetch ──────────────────────────────────────────────────────────────
def fetch_logistics_news() -> list:
    """Fetch recent headlines from NewsAPI across all our Indian logistics queries."""
    if not NEWS_API_KEY:
        print("[NEWS] ⚠️  NEWS_API_KEY not set — using simulated headlines for demo")
        return _simulated_headlines()

    all_articles = []
    seen_titles = set()
    for query in LOGISTICS_QUERIES:
        try:
            r = requests.get(
                "https://newsapi.org/v2/everything",
                params={
                    "q": query,
                    "sortBy": "publishedAt",
                    "pageSize": 5,
                    "language": "en",
                    "apiKey": NEWS_API_KEY,
                },
                timeout=10,
            )
            r.raise_for_status()
            for article in r.json().get("articles", []):
                title = article.get("title", "")
                if title and title not in seen_titles:
                    seen_titles.add(title)
                    all_articles.append(article)
        except Exception as e:
            print(f"[NEWS] Error fetching '{query}': {e}")

    print(f"[NEWS] Fetched {len(all_articles)} unique articles")
    return all_articles


def _simulated_headlines() -> list:
    """Return realistic simulated headlines for demo mode (no API key needed)."""
    import random
    headlines = [
        {
            "title": "Chennai Port workers begin indefinite strike over wage dispute",
            "description": "CITU-affiliated dock workers at Chennai Port have begun an indefinite strike, halting operations at berths 1-8. Over 40 container vessels affected.",
            "publishedAt": datetime.datetime.utcnow().isoformat(),
            "source": {"name": "The Hindu"},
        },
        {
            "title": "NH-44 blocked near Krishnagiri due to multi-vehicle pile-up",
            "description": "A 12-vehicle accident on National Highway 44 near Krishnagiri has blocked northbound freight traffic. Trucks diverted via Vellore.",
            "publishedAt": datetime.datetime.utcnow().isoformat(),
            "source": {"name": "Times of India"},
        },
        {
            "title": "Cyclone Tej: Mumbai port suspends operations, vessels anchored offshore",
            "description": "Mumbai Port Trust has suspended all port operations until further notice as Cyclone Tej approaches the Maharashtra coast with wind speeds of 120 kmph.",
            "publishedAt": datetime.datetime.utcnow().isoformat(),
            "source": {"name": "Economic Times"},
        },
    ]
    # Return 1 random headline per poll to simulate real trickle
    return [random.choice(headlines)]


def _deduplicate(articles: list) -> list:
    fresh = []
    for a in articles:
        text = (a.get("title", "") + a.get("description", "")).strip()
        h = hashlib.md5(text.encode()).hexdigest()
        if h not in _seen_hashes and text:
            a["_hash"] = h
            fresh.append(a)
    return fresh


# ── Gemini analysis (reuses existing gemini_client) ──────────────────────────
def _analyze_with_gemini(article: dict) -> Optional[dict]:
    """
    Run the existing Gemini client on a news article.
    Returns structured disruption data or None if not a real disruption.
    """
    try:
        from .gemini_client import parse_news_headline
        headline = article.get("title", "")
        desc = article.get("description", "") or ""
        full_text = f"{headline}. {desc}"
        result = parse_news_headline(full_text)
        # Filter out non-disruptions
        if result.get("type") == "none" or result.get("severity", 0) < 0.3:
            return None
        result["headline"] = headline
        result["source"] = article.get("source", {}).get("name", "Unknown")
        result["published_at"] = article.get("publishedAt", "")
        return result
    except Exception as e:
        print(f"[GEMINI] Analysis error: {e}")
        return None


# ── GNN cascade (calls existing gnn_cascade module) ──────────────────────────
def _run_cascade(gemini_result: dict) -> Optional[dict]:
    """Map Gemini location → hub and run the GNN cascade predictor."""
    try:
        from .gnn_cascade import predict_cascade_gnn
        location = gemini_result.get("location") or "Chennai Port"
        result = predict_cascade_gnn(
            disrupted_hub_name=location,
            severity=gemini_result.get("severity", 0.5),
        )
        return result
    except Exception as e:
        print(f"[GNN] Cascade error: {e}")
        return None


# ── Route optimization ────────────────────────────────────────────────────────
def _optimize(cascade_result: Optional[dict]) -> list:
    """Run route optimizer on affected shipments from the cascade."""
    if not cascade_result:
        return []
    try:
        from .route_optimizer import optimize_routes
        affected_ids = [s["shipment_id"] for s in cascade_result.get("affected_shipments", [])[:10]]
        blocked_hubs = [cascade_result.get("disrupted_hub", "")]
        if not affected_ids:
            return []
        return optimize_routes(
            affected_shipment_ids=affected_ids,
            blocked_hub_ids=[h for h in blocked_hubs if h],
        )
    except Exception as e:
        print(f"[OPTIMIZER] Error: {e}")
        return []


# ── Firestore write ────────────────────────────────────────────────────────────
def _write_to_firestore(article: dict, gemini: dict, cascade: Optional[dict], routes: list):
    """
    Write a complete disruption event to Firestore.
    Flutter's StreamBuilder picks this up in <1 second automatically.

    Collection structure:
        disruptions/{event_id}          ← the live disruption event
        disruptions/{event_id}/routes   ← optimized alternative routes
        realtime_status/latest          ← single doc Flutter polls for last update
    """
    if not _firebase_ok or _db is None:
        # Store in memory for the /realtime/events endpoint fallback
        _in_memory_events.insert(0, {
            "gemini": gemini,
            "cascade": cascade,
            "routes": routes,
            "timestamp": datetime.datetime.utcnow().isoformat(),
        })
        if len(_in_memory_events) > 50:
            _in_memory_events.pop()
        return

    from firebase_admin import firestore as fs
    event_id = article["_hash"]
    now = fs.SERVER_TIMESTAMP

    event_doc = {
        "id": event_id,
        "headline": gemini.get("headline", ""),
        "source": gemini.get("source", ""),
        "published_at": gemini.get("published_at", ""),
        "type": gemini.get("type", "other"),
        "location": gemini.get("location"),
        "severity": gemini.get("severity", 0.5),
        "affected_mode": gemini.get("affected_mode", "unknown"),
        "confidence": gemini.get("confidence", 0.7),
        "cascade_probability": cascade.get("cascade_probability", 0) if cascade else 0,
        "shipments_at_risk": len(cascade.get("affected_shipments", [])) if cascade else 0,
        "affected_hubs": cascade.get("affected_hubs", []) if cascade else [],
        "estimated_delay_hours": cascade.get("max_delay_hours", 0) if cascade else 0,
        "reroutes_available": len(routes),
        "status": "active",
        "created_at": now,
        "updated_at": now,
        "is_realtime": True,   # flag to distinguish from demo/simulated events
    }

    # Write main disruption document
    _db.collection("disruptions").document(event_id).set(event_doc)

    # Write routes as subcollection
    for i, route in enumerate(routes):
        _db.collection("disruptions").document(event_id)\
           .collection("routes").document(str(i)).set(route)

    # Update the "latest event" document Flutter polls for status bar
    _db.collection("realtime_status").document("latest").set({
        "last_updated": now,
        "last_event_id": event_id,
        "last_headline": gemini.get("headline", ""),
        "last_severity": gemini.get("severity", 0.5),
        "active_disruptions": fs.Increment(1),
    }, merge=True)

    severity = gemini.get("severity", 0)
    sev_label = "CRITICAL" if severity >= 0.8 else "HIGH" if severity >= 0.6 else "MEDIUM"
    print(f"[FIRESTORE] ✅ Written [{sev_label}] {gemini.get('headline', '')[:60]}")


# ── In-memory fallback (no Firebase) ─────────────────────────────────────────
_in_memory_events: list = []

def get_recent_events(limit: int = 20) -> list:
    """Used by /realtime/events endpoint when Firebase is not configured."""
    return _in_memory_events[:limit]


# ── Main poll loop ─────────────────────────────────────────────────────────────
_poller_thread: Optional[threading.Thread] = None
_running = False

def _poll_once():
    """Run one full poll cycle: fetch → deduplicate → analyze → cascade → write."""
    print(f"\n[POLLER] 🔄 Poll cycle starting at {datetime.datetime.utcnow().isoformat()}")
    articles = fetch_logistics_news()
    fresh = _deduplicate(articles)
    print(f"[POLLER] {len(fresh)} new articles to process")



    skipped = 0
    for article in fresh:
        if skipped >= 2:
            print(f"[POLLER] ⏹ Reached 2 non-logistics skips, stopping cycle early")
            break

        title = article.get("title", "")[:60]
        print(f"[POLLER] Processing: {title}...")

        gemini_result = _analyze_with_gemini(article)
        if not gemini_result:
            print(f"[POLLER] ↩ Not a logistics disruption, skipping ({skipped+1}/4)")
            _mark_seen(article["_hash"])
            skipped += 1
            continue

        cascade_result = _run_cascade(gemini_result)
        routes = _optimize(cascade_result)

        _write_to_firestore(article, gemini_result, cascade_result, routes)
        _mark_seen(article["_hash"])

    print(f"[POLLER] ✅ Poll cycle done. Next poll in {POLL_INTERVAL}s")


def _poller_loop():
    """Background thread loop."""
    _load_seen_hashes()
    while _running:
        try:
            _poll_once()
        except Exception as e:
            print(f"[POLLER] ❌ Unhandled error in poll cycle: {e}")
        time.sleep(POLL_INTERVAL)


def start_poller():
    """Start the background poller thread. Called from main.py on startup."""
    global _poller_thread, _running
    _init_firebase()
    if _poller_thread and _poller_thread.is_alive():
        print("[POLLER] Already running")
        return
    _running = True
    _poller_thread = threading.Thread(target=_poller_loop, daemon=True, name="realtime-poller")
    _poller_thread.start()
    print(f"[POLLER] 🚀 Started — polling every {POLL_INTERVAL}s")


def stop_poller():
    """Gracefully stop the poller (used in tests)."""
    global _running
    _running = False


# ── Standalone run ────────────────────────────────────────────────────────────
if __name__ == "__main__":
    print("ResilientNet Realtime Poller — standalone mode")
    print(f"  NEWS_API_KEY:   {'set ✅' if NEWS_API_KEY else 'NOT SET ⚠️  (demo mode)'}")
    print(f"  FIREBASE_CREDS: {FIREBASE_CREDS}")
    print(f"  POLL_INTERVAL:  {POLL_INTERVAL}s")
    _init_firebase()
    _load_seen_hashes()
    while True:
        try:
            _poll_once()
        except KeyboardInterrupt:
            print("\n[POLLER] Stopped by user")
            break
        except Exception as e:
            print(f"[POLLER] Error: {e}")
        time.sleep(POLL_INTERVAL)