"""
server.py

Server utama FastAPI untuk IoT+AI Push-up Tracker.

Jalankan:
    uvicorn server:app --host 0.0.0.0 --port 8000

Komponen:
  1. /ws/mobile  — WebSocket, broadcast vision state ke Flutter client (~20 Hz)
  2. /health     — HTTP GET, status server
  3. Background  — Loop webcam + PostureDetector (jalan di thread terpisah)
  4. Session     — Tracking target reps, per-rep quality, dan recap
"""

import asyncio
import json
import logging
import time
import socket
import threading
from contextlib import asynccontextmanager

import cv2
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.responses import JSONResponse

from posture_detector import PostureDetector

# ─── Logging ─────────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)-7s | %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("pushup-server")

# ─── Shared State ────────────────────────────────────────────────────────

# Hasil terbaru dari masing-masing modul
latest_vision_result: dict = {
    "pose_detected": False,
    "status": "unknown",
    "issues": [],
    "elbow_angle": None,
    "hip_deviation": None,
    "in_pushup_position": False,
    "rep_quality": "perfect",
}

# Status koneksi
camera_running: bool = False
pushup_ready: bool = False

# Instance modul
posture_detector = PostureDetector()

# Mobile WebSocket clients
mobile_clients: set[WebSocket] = set()

# Flag untuk shutdown graceful
_shutdown_event = asyncio.Event()

# ─── Session State ───────────────────────────────────────────────────────
session_active: bool = False
session_target_reps: int = 0
session_rep_history: list[dict] = []

# State counting rep dari vision
server_rep_count: int = 0
vision_is_up: bool = True
has_been_ready: bool = False
current_rep_series: list = []
rep_state = "up"
debounce_counter = 0

def _reset_session():
    """Reset session state."""
    global session_active, session_target_reps, session_rep_history
    global server_rep_count, vision_is_up, current_rep_series, has_been_ready
    global rep_state, debounce_counter
    session_active = False
    session_target_reps = 0
    session_rep_history = []
    server_rep_count = 0
    vision_is_up = True
    has_been_ready = False
    current_rep_series = []
    rep_state = "up"
    debounce_counter = 0


# ─── Fused State ────────────────────────────────────────────────────────
def build_fused_state() -> dict:
    """Gabungkan hasil vision jadi satu dict sesuai format spek."""
    return {
        "timestamp": int(time.time() * 1000),  # unix ms
        "rep_count": server_rep_count,  # rep_count dari Vision
        "posture_status": latest_vision_result.get("status", "unknown"),
        "posture_issues": latest_vision_result.get("issues", []),
        "movement_status": "unknown",
        "movement_issues": [],
        "elbow_angle": latest_vision_result.get("elbow_angle"),
        "hip_deviation": latest_vision_result.get("hip_deviation"),
        "pushup_ready": pushup_ready,
        "connection": {
            "esp32": False, # Di-override oleh flutter
            "camera": camera_running,
        },
        "session": {
            "active": session_active,
            "target_reps": session_target_reps,
            "rep_history": session_rep_history,
        },
    }


# ─── Webcam Worker (Native Thread) ──────────────────────────────────────
def _camera_worker():
    """Worker thread untuk memproses webcam & MediaPipe tanpa memblokir asyncio."""
    global camera_running, latest_vision_result, pushup_ready
    global server_rep_count, debounce_counter, rep_state, session_rep_history

    cap = cv2.VideoCapture(0)
    if not cap.isOpened():
        log.error("❌ Kamera tidak dapat dibuka")
        return

    camera_running = True
    log.info("📷 Webcam aktif — mulai analisa postur di background thread")
    
    DEBOUNCE_THRESHOLD = 2

    try:
        while not _shutdown_event.is_set():
            ret, frame = cap.read()
            if not ret:
                time.sleep(0.1)
                continue

            # Analisa postur via MediaPipe (CPU Intensive)
            result, annotated = posture_detector.analyze(frame)
            latest_vision_result = result

            # Debounce posisi 'ready'
            in_pos = result.get("in_pushup_position", False)
            if in_pos:
                debounce_counter = min(DEBOUNCE_THRESHOLD, debounce_counter + 1)
            else:
                debounce_counter = max(0, debounce_counter - 1)

            if debounce_counter == DEBOUNCE_THRESHOLD:
                pushup_ready = True
            elif debounce_counter == 0:
                pushup_ready = False

            # --- REP COUNTING VISION ---
            if session_active and pushup_ready:
                status = result.get("status", "unknown")
                issues = result.get("issues", [])
                elbow = result.get("elbow_angle")
                hip = result.get("hip_deviation")
                
                if elbow is None:
                    elbow = 180
                if hip is None:
                    hip = 0

                # State machine
                if rep_state == "up":
                    if elbow < posture_detector.DEPTH_ELBOW_ANGLE and status == "good":
                        rep_state = "down"
                elif rep_state == "down":
                    if elbow > posture_detector.TOP_ELBOW_ANGLE:
                        server_rep_count += 1
                        rep_state = "up"
                        quality = "perfect" if not issues else "imperfect"
                        
                        record = {
                            "rep_number": server_rep_count,
                            "quality": quality,
                            "issues": issues,
                            "elbow_angle": elbow,
                            "hip_deviation": hip,
                            "timestamp": int(time.time() * 1000)
                        }
                        session_rep_history.append(record)
                        log.info("🏋️  [Vision] Rep terdeteksi — total %d", server_rep_count)

            # Tidur sebentar agar tidak memakan 100% CPU core
            time.sleep(0.01)
    except Exception as e:
        log.error("Kamera error: %s", e)
    finally:
        cap.release()
        camera_running = False
        log.info("📷 Webcam dilepas")


# ─── Broadcast ke Mobile ────────────────────────────────────────────────
async def _broadcast_loop():
    """Mengirim data secara konstan dan mulus ke Flutter pada 20Hz (0.05s)."""
    while not _shutdown_event.is_set():
        if mobile_clients:
            fused_state = build_fused_state()
            payload = json.dumps(fused_state)
            stale: list[WebSocket] = []
            for ws in list(mobile_clients):
                try:
                    await ws.send_text(payload)
                except Exception:
                    stale.append(ws)
            for ws in stale:
                mobile_clients.discard(ws)
                log.info("📱 Mobile client terputus saat broadcast — dibuang dari daftar")
        await asyncio.sleep(0.05)


# ─── Lifespan ────────────────────────────────────────────────────────────
@asynccontextmanager
async def lifespan(app: FastAPI):
    """Startup & shutdown hooks."""
    log.info("🚀 Server starting …")

    # Jalankan webcam di thread & broadcast loop sebagai background task
    camera_thread = threading.Thread(target=_camera_worker, daemon=True)
    camera_thread.start()

    # Jalankan loop broadcast
    broadcast_task = asyncio.create_task(_broadcast_loop())

    yield  # server berjalan

    # Shutdown
    log.info("🛑 Server shutting down …")
    _shutdown_event.set()
    broadcast_task.cancel()
    try:
        await broadcast_task
    except asyncio.CancelledError:
        pass


# ─── FastAPI App ─────────────────────────────────────────────────────────
app = FastAPI(
    title="Push-up Tracker Server",
    description="IoT+AI push-up tracker — server khusus kamera",
    lifespan=lifespan,
)


# ─── Mobile Message Handler ─────────────────────────────────────────────
def _handle_mobile_message(raw: str):
    """Proses pesan dari mobile client (start session, reset, dll)."""
    global session_active, session_target_reps
    try:
        msg = json.loads(raw)
    except json.JSONDecodeError:
        return

    action = msg.get("action")

    if action == "start_session":
        target = msg.get("target_reps", 10)
        _reset_session()
        session_active = True
        session_target_reps = target
        log.info("🎯 Session dimulai — target %d reps", target)

    elif action == "end_session":
        session_active = False
        log.info("🏁 Session diakhiri — total %d reps tercatat", len(session_rep_history))

    elif action == "reset_session":
        _reset_session()
        log.info("🔄 Session di-reset")


# ─── WebSocket /ws/mobile ─────────────────────────────────────────────
@app.websocket("/ws/mobile")
async def ws_mobile(ws: WebSocket):
    """Koneksi WebSocket dari client Flutter / browser."""
    await ws.accept()
    mobile_clients.add(ws)
    log.info("📱 Mobile client terhubung — total %d client(s)", len(mobile_clients))

    try:
        # Tetap buka koneksi — terima pesan dari mobile (session commands).
        # Broadcast dilakukan oleh _broadcast_loop, bukan di sini.
        while True:
            raw = await ws.receive_text()
            _handle_mobile_message(raw)
    except WebSocketDisconnect:
        pass
    except Exception:
        pass
    finally:
        mobile_clients.discard(ws)
        log.info("📱 Mobile client terputus — sisa %d client(s)", len(mobile_clients))


# ─── HTTP /health ─────────────────────────────────────────────────────
@app.get("/health")
async def health():
    """Status server dan kamera."""
    return JSONResponse({
        "status": "ok",
        "camera_running": camera_running,
        "mobile_clients": len(mobile_clients),
        "pushup_ready": pushup_ready,
        "rep_count": server_rep_count,
        "session_active": session_active,
        "session_target_reps": session_target_reps,
        "session_reps_recorded": len(session_rep_history),
    })
