"""
Gemini API client — parses unstructured news into structured disruption events.
Using gemini-1.0-pro (base model) — stable, widely available on free tier.
"""

import os
import json
import re
import time
from typing import Dict

from dotenv import load_dotenv
load_dotenv()

GEMINI_KEY = os.environ.get("GEMINI_API_KEY", "").strip()
GEMINI_AVAILABLE = bool(GEMINI_KEY)

_model = None
if GEMINI_AVAILABLE:
    try:
        import google.generativeai as genai
        genai.configure(api_key=GEMINI_KEY)
        _model = genai.GenerativeModel("gemini-2.5-flash-lite")
        print("[GEMINI] ✅ Initialized with gemini-2.5-flash-lite")
    except Exception as e:
        print(f"Gemini init failed: {e}")
        GEMINI_AVAILABLE = False


PROMPT_TEMPLATE = """You are analyzing a news headline for supply chain disruption signals.
Return a JSON object with EXACTLY these fields:

- type: one of ["storm", "strike", "accident", "closure", "conflict", "other", "none"]
- location: best-guess city, region, port, or country (or null if not identifiable)
- severity: number from 0.0 (very minor) to 1.0 (catastrophic disruption)
- affected_mode: one of ["sea", "air", "land", "multi", "unknown"]
- confidence: your confidence in this analysis, 0.0 to 1.0

If the headline does not describe a real supply chain disruption, set type="none" and severity=0.0.

Return ONLY valid JSON, no markdown fences, no explanation.

Headline: "{headline}"
"""


def _fallback_parse(headline: str) -> Dict:
    """Simple keyword matching fallback when Gemini isn't available."""
    text = headline.lower()

    type_map = {
        "storm":    ["storm", "cyclone", "hurricane", "typhoon", "monsoon", "flood"],
        "strike":   ["strike", "walkout", "protest", "blockade", "union"],
        "accident": ["accident", "crash", "collision", "derail", "fire"],
        "closure":  ["closure", "shut", "blocked", "halted", "suspended", "grounded"],
        "conflict": ["attack", "drone", "missile", "houthi", "conflict", "war"],
    }
    detected_type = "other"
    for t, keywords in type_map.items():
        if any(kw in text for kw in keywords):
            detected_type = t
            break

    locations = re.findall(r"\b[A-Z][a-z]+(?:\s[A-Z][a-z]+)*\b", headline)
    common_words = {"The", "A", "An", "Breaking"}
    locations = [l for l in locations if l not in common_words]
    location = locations[0] if locations else None

    severity = 0.5
    if any(kw in text for kw in ["attack", "catastrophic", "severe", "major"]):
        severity = 0.85
    elif any(kw in text for kw in ["minor", "slight", "brief"]):
        severity = 0.3

    if any(kw in text for kw in ["shipping", "port", "vessel", "sea", "strait"]):
        mode = "sea"
    elif any(kw in text for kw in ["flight", "airport", "airspace", "air"]):
        mode = "air"
    elif any(kw in text for kw in ["highway", "road", "truck", "rail"]):
        mode = "land"
    else:
        mode = "unknown"

    return {
        "type": detected_type,
        "location": location,
        "severity": severity,
        "affected_mode": mode,
        "confidence": 0.6,
        "raw_response": "(fallback keyword matcher — no Gemini key set)",
    }


def parse_news_headline(headline: str, max_retries: int = 3) -> Dict:
    """
    Send a news headline to Gemini, receive structured disruption JSON.
    Falls back to keyword matching if Gemini fails.
    """
    if not GEMINI_AVAILABLE or _model is None:
        return _fallback_parse(headline)

    prompt = PROMPT_TEMPLATE.format(headline=headline.replace('"', "'"))
    retry_delay = 15

    for attempt in range(max_retries):
        try:
            response = _model.generate_content(prompt)
            text = response.text.strip()
            text = re.sub(r"^```(?:json)?\s*", "", text)
            text = re.sub(r"\s*```$", "", text)
            parsed = json.loads(text)
            return {
                "type": parsed.get("type", "other"),
                "location": parsed.get("location"),
                "severity": float(parsed.get("severity", 0.5)),
                "affected_mode": parsed.get("affected_mode", "unknown"),
                "confidence": float(parsed.get("confidence", 0.85)),
                "raw_response": text,
            }
        except Exception as e:
            err_str = str(e)
            is_quota = "429" in err_str or "quota" in err_str.lower()
            if is_quota and attempt < max_retries - 1:
                print(f"[GEMINI] Rate limit (attempt {attempt+1}/{max_retries}). Retrying in {retry_delay}s...")
                time.sleep(retry_delay)
                retry_delay *= 2
                continue
            print(f"Gemini parse failed, using fallback: {e}")
            result = _fallback_parse(headline)
            result["raw_response"] = f"(Gemini failed: {e} — fallback used)"
            return result