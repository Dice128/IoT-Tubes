"""
server.py

Server utama FastAPI untuk IoT+AI Push-up Tracker.

Jalankan:
    uvicorn server:app --host 0.0.0.0 --port 8000

Komponen:
  1. /ws/esp32   — WebSocket, terima data IMU dari ESP32 (~20 Hz)
  2. /ws/mobile  — WebSocket, broadcast fused state ke Flutter client (~5-7 Hz)
  3. /health     — HTTP GET, status server
  4. Background  — Loop webcam + PostureDetector (jalan di thread terpisah)
  5. Fusion      — Gabungkan hasil MovementAnalyzer (IMU) + PostureDetector (vision)
  6. Session     — Tracking target reps, per-rep quality, dan recap
"""

import asyncio
import collections
import json
import logging
import time
from contextlib import asynccontextmanager

import cv2
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.responses import JSONResponse

from movement_analyzer import MovementAnalyzer
from posture_detector import PostureDetector

# ─── Logging ─────────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)-7s | %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("pushup-server")

# ─── Shared State ────────────────────────────────────────────────────────
# Buffer IMU — simpan ~5 detik data terakhir (20 Hz × 5 s = 100 sampel)
IMU_BUFFER_SIZE = 100
imu_buffer: collections.deque = collections.deque(maxlen=IMU_BUFFER_SIZE)

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
latest_imu_result: dict = {
    "rep_count": 0,
    "movement_status": "unknown",
    "movement_issues": [],
}

# Status koneksi
esp32_connected: bool = False
esp32_ws: WebSocket | None = None
camera_running: bool = False
pushup_ready: bool = False

# Instance modul
movement_analyzer = MovementAnalyzer()
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

# [TAMBAHAN] State untuk anti-false-positive rep counting
_smoothed_elbow_angle: float | None = None  # EMA-filtered elbow angle
_last_rep_time: float = 0.0                  # waktu rep terakhir (time.time())
_down_entry_time: float = 0.0                # waktu pertama masuk posisi bawah
_confirmed_down: bool = False                 # sudah confirmed posisi bawah

# Konstanta rep counting
REP_COOLDOWN_SEC = 0.8        # minimum jeda antar 2 rep diturunkan agar lebih sensitif
DOWN_HOLD_MIN_SEC = 0.1       # hold time dikurangi jadi 100ms
ELBOW_EMA_ALPHA = 0.6         # smoothing factor dinaikkan agar lebih responsif terhadap perubahan


def _reset_session():
    """Reset session state."""
    global session_active, session_target_reps, session_rep_history
    global server_rep_count, vision_is_up, current_rep_series, has_been_ready
    global _smoothed_elbow_angle, _last_rep_time, _down_entry_time, _confirmed_down
    session_active = False
    session_target_reps = 0
    session_rep_history = []
    server_rep_count = 0
    vision_is_up = True
    has_been_ready = False
    current_rep_series = []
    _smoothed_elbow_angle = None
    _last_rep_time = 0.0
    _down_entry_time = 0.0
    _confirmed_down = False


def _record_rep(rep_number: int):
    """Catat kualitas satu rep berdasarkan state vision + IMU terkini."""
    posture_issues = latest_vision_result.get("issues", [])
    movement_issues = latest_imu_result.get("movement_issues", [])
    all_issues = posture_issues + movement_issues
    rep_quality = latest_vision_result.get("rep_quality", "perfect")
    if all_issues:
        rep_quality = "imperfect"

    global current_rep_series
    record = {
        "rep_number": rep_number,
        "quality": rep_quality,
        "issues": all_issues,
        "elbow_angle": latest_vision_result.get("elbow_angle"),
        "hip_deviation": latest_vision_result.get("hip_deviation"),
        "gyro_magnitude": latest_imu_result.get("gyro_magnitude"),
        "accel_jitter": latest_imu_result.get("accel_jitter"),
        "series_data": current_rep_series.copy(),
        "timestamp": int(time.time() * 1000),
    }
    session_rep_history.append(record)
    current_rep_series.clear()
    log.info(
        "📊 Rep #%d recorded — quality=%s, issues=%s",
        rep_number,
        rep_quality,
        all_issues,
    )


# ─── Fusion Logic ────────────────────────────────────────────────────────
def build_fused_state() -> dict:
    """Gabungkan hasil IMU + vision jadi satu dict sesuai format spek."""
    return {
        "timestamp": int(time.time() * 1000),  # unix ms
        "rep_count": server_rep_count,  # rep_count dari Vision (bukan IMU)
        "posture_status": latest_vision_result.get("status", "unknown"),
        "posture_issues": latest_vision_result.get("issues", []),
        "movement_status": latest_imu_result.get("movement_status", "unknown"),
        "movement_issues": latest_imu_result.get("movement_issues", []),
        "elbow_angle": latest_vision_result.get("elbow_angle"),
        "hip_deviation": latest_vision_result.get("hip_deviation"),
        "pushup_ready": pushup_ready,
        "connection": {
            "esp32": esp32_connected,
            "camera": camera_running,
        },
        "session": {
            "active": session_active,
            "target_reps": session_target_reps,
            "rep_history": session_rep_history,
        },
    }


# ─── Webcam Loop (blocking → jalankan di thread) ────────────────────────
def _webcam_loop_blocking():
    """
    Berjalan di thread terpisah (bukan di event loop asyncio).
    Capture frame dari webcam, panggil PostureDetector.analyze() tiap frame.

    [DIUBAH] Rep counting sekarang menggunakan:
    - EMA smoothing pada sudut siku (anti-flicker MediaPipe)
    - Cooldown 1.5 detik antar rep (push-up realistis ~2-3s per rep)
    - Minimum hold time 300ms di posisi bawah (anti-noise)
    """
    global latest_vision_result, camera_running, pushup_ready
    global server_rep_count, vision_is_up, current_rep_series, has_been_ready
    global _smoothed_elbow_angle, _last_rep_time, _down_entry_time, _confirmed_down

    cap = cv2.VideoCapture(0)
    if not cap.isOpened():
        log.warning("⚠  Webcam tidak bisa dibuka — modul vision nonaktif")
        camera_running = False
        return

    camera_running = True
    log.info("📷 Webcam aktif — mulai analisa postur")

    debounce_counter = 0
    DEBOUNCE_THRESHOLD = 5

    try:
        while not _shutdown_event.is_set():
            ok, frame = cap.read()
            if not ok:
                log.warning("⚠  Gagal baca frame dari webcam")
                break

            result, _annotated = posture_detector.analyze(frame)
            latest_vision_result = result

            # Rep counting logic using vision
            raw_angle = result.get("elbow_angle")
            hip = result.get("hip_deviation")

            # ── EMA smoothing pada sudut siku ──
            if raw_angle is not None:
                if _smoothed_elbow_angle is None:
                    _smoothed_elbow_angle = raw_angle
                else:
                    _smoothed_elbow_angle += ELBOW_EMA_ALPHA * (raw_angle - _smoothed_elbow_angle)
            angle = _smoothed_elbow_angle  # pakai sudut yang sudah di-smooth

            if session_active and angle is not None:
                current_rep_series.append({
                    "elbow_angle": round(angle, 1),
                    "hip_deviation": hip if hip is not None else 0.0,
                    "timestamp": int(time.time() * 1000)
                })

            # Debounce logic untuk pushup_ready
            in_pos = result.get("in_pushup_position", False)
            if in_pos:
                debounce_counter = min(DEBOUNCE_THRESHOLD, debounce_counter + 1)
            else:
                debounce_counter = max(0, debounce_counter - 1)

            if debounce_counter == DEBOUNCE_THRESHOLD:
                pushup_ready = True
                has_been_ready = True  # Tandai bahwa user sudah siap setidaknya sekali
            elif debounce_counter == 0:
                pushup_ready = False

            # ── Rep counting dengan cooldown + hold time ──
            now = time.time()
            if angle is not None and has_been_ready:
                if vision_is_up and angle < PostureDetector.DEPTH_ELBOW_ANGLE:
                    # Masuk posisi bawah — catat waktu masuk
                    if _down_entry_time == 0.0:
                        _down_entry_time = now

                    # Cek apakah sudah hold cukup lama di bawah
                    if (now - _down_entry_time) >= DOWN_HOLD_MIN_SEC:
                        vision_is_up = False
                        _confirmed_down = True
                else:
                    # Sudut di atas threshold bawah — reset timer down
                    if vision_is_up:
                        _down_entry_time = 0.0

                if _confirmed_down and angle > PostureDetector.TOP_ELBOW_ANGLE:
                    # Cek cooldown — jangan hitung rep terlalu cepat
                    if (now - _last_rep_time) >= REP_COOLDOWN_SEC:
                        vision_is_up = True
                        _confirmed_down = False
                        _down_entry_time = 0.0
                        _last_rep_time = now
                        server_rep_count += 1

                        if session_active:
                            _record_rep(server_rep_count)
                            log.info(
                                "🏋️  [Vision] Rep baru terdeteksi — total %d",
                                server_rep_count,
                            )
                        else:
                            log.info(
                                "🏋️  [Vision] Rep terdeteksi (session belum aktif) — total %d",
                                server_rep_count,
                            )
                    else:
                        # Cooldown belum habis — reset state tanpa hitung rep
                        vision_is_up = True
                        _confirmed_down = False
                        _down_entry_time = 0.0
                        log.debug(
                            "⏳ Rep diabaikan (cooldown belum habis, %.1fs tersisa)",
                            REP_COOLDOWN_SEC - (now - _last_rep_time),
                        )

    finally:
        cap.release()
        camera_running = False
        log.info("📷 Webcam dilepas")


async def _start_webcam_background():
    """Jalankan webcam loop di thread supaya tidak memblok event loop."""
    loop = asyncio.get_running_loop()
    await loop.run_in_executor(None, _webcam_loop_blocking)


# ─── Broadcast ke Mobile ────────────────────────────────────────────────
async def _broadcast_loop():
    """Kirim fused state ke semua mobile client setiap ~100 ms (~10 Hz)."""
    while not _shutdown_event.is_set():
        # Kirim sinyal pushup_ready ke ESP32 sebagai heartbeat
        if esp32_ws and esp32_connected:
            try:
                await esp32_ws.send_text(json.dumps({"pushup_ready": pushup_ready}))
            except Exception:
                pass

        if mobile_clients:
            payload = json.dumps(build_fused_state())
            stale: list[WebSocket] = []
            for ws in list(mobile_clients):
                try:
                    await ws.send_text(payload)
                except Exception:
                    stale.append(ws)
            for ws in stale:
                mobile_clients.discard(ws)
                log.info("📱 Mobile client terputus saat broadcast — dibuang dari daftar")
        await asyncio.sleep(0.10)  # [DIUBAH] ~10 Hz (dari 6.7 Hz) untuk UI lebih responsif


# ─── Lifespan ────────────────────────────────────────────────────────────
@asynccontextmanager
async def lifespan(app: FastAPI):
    """Startup & shutdown hooks."""
    log.info("🚀 Server starting …")

    # Jalankan webcam di thread & broadcast loop sebagai background task
    webcam_task = asyncio.create_task(_start_webcam_background())
    broadcast_task = asyncio.create_task(_broadcast_loop())

    yield  # server berjalan

    # Shutdown
    log.info("🛑 Server shutting down …")
    _shutdown_event.set()
    broadcast_task.cancel()
    webcam_task.cancel()
    try:
        await broadcast_task
    except asyncio.CancelledError:
        pass
    try:
        await webcam_task
    except asyncio.CancelledError:
        pass


# ─── FastAPI App ─────────────────────────────────────────────────────────
app = FastAPI(
    title="Push-up Tracker Server",
    description="IoT+AI push-up tracker — fusi data IMU (ESP32) dan vision (webcam)",
    lifespan=lifespan,
)


# ─── 1. WebSocket /ws/esp32 ──────────────────────────────────────────────
@app.websocket("/ws/esp32")
async def ws_esp32(ws: WebSocket):
    """Terima data IMU dari ESP32 lewat WebSocket."""
    global esp32_connected, latest_imu_result, esp32_ws

    await ws.accept()
    esp32_connected = True
    esp32_ws = ws
    log.info("🔌 ESP32 terhubung")

    try:
        while True:
            raw = await ws.receive_text()
            try:
                sample = json.loads(raw)
            except json.JSONDecodeError:
                log.warning("⚠  JSON tidak valid dari ESP32: %s", raw[:80])
                continue

            # Simpan ke buffer
            imu_buffer.append(sample)

            # Analisa gerakan kualitas
            result = movement_analyzer.update(sample)
            latest_imu_result = result

    except WebSocketDisconnect:
        log.info("🔌 ESP32 terputus")
    except Exception as exc:
        log.error("❌ Error pada koneksi ESP32: %s", exc)
    finally:
        esp32_connected = False


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


# ─── 5. WebSocket /ws/mobile ─────────────────────────────────────────────
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


# ─── 6. HTTP /health ─────────────────────────────────────────────────────
@app.get("/health")
async def health():
    """Status server, koneksi ESP32, dan kamera."""
    return JSONResponse({
        "status": "ok",
        "esp32_connected": esp32_connected,
        "camera_running": camera_running,
        "mobile_clients": len(mobile_clients),
        "imu_buffer_size": len(imu_buffer),
        "pushup_ready": pushup_ready,
        "rep_count": server_rep_count,
        "session_active": session_active,
        "session_target_reps": session_target_reps,
        "session_reps_recorded": len(session_rep_history),
    })
