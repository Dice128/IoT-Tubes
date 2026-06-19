"""
movement_analyzer.py

Modul analisa gerakan push-up dari data IMU (MPU6050/6500).
Mendeteksi pola naik-turun dari sinyal akselerometer/giroskop menggunakan:
  - Low-pass filter (exponential moving average)
  - Peak / valley detection dengan threshold & refractory period
  - State machine "up" / "down" (konsep serupa posture_detector.py)

Input : satu sample IMU dict {"ax","ay","az","gx","gy","gz"}
Output: {"rep_count": int, "movement_status": str, "movement_issues": [str]}
"""

import math
import time


class MovementAnalyzer:
    # ─── Threshold & konstanta ───────────────────────────────────────────
    # Semua nilai di bawah ini TEBAKAN AWAL — harus dikalibrasi dengan
    # data MPU6050 nyata saat subjek push-up.

    # TODO: kalibrasi — koefisien EMA low-pass filter (0-1, semakin kecil = semakin halus)
    LPF_ALPHA = 0.25

    # TODO: kalibrasi — threshold percepatan vertikal (m/s²) untuk deteksi puncak/lembah
    #   Saat push-up: badan turun → ay naik (gravitasi + gerak),
    #                  badan naik  → ay turun
    #   Sumbu bergantung orientasi sensor di badan; az sering jadi sumbu
    #   vertikal kalau sensor rata di punggung.
    ACCEL_UP_THRESHOLD = 11.5    # TODO: kalibrasi — di atas ini = posisi "up"
    ACCEL_DOWN_THRESHOLD = 8.5   # TODO: kalibrasi — di bawah ini = posisi "down"

    # TODO: kalibrasi — refractory period (detik) supaya tidak double-count
    REFRACTORY_SECONDS = 0.6

    # TODO: kalibrasi — threshold gyroscope (rad/s) untuk deteksi gerakan terlalu cepat
    GYRO_SPEED_LIMIT = 5.0

    # TODO: kalibrasi — threshold variasi akselerasi untuk deteksi gerakan tidak stabil
    ACCEL_JITTER_LIMIT = 4.0

    # TODO: kalibrasi — jumlah sampel terakhir untuk hitung jitter
    JITTER_WINDOW_SIZE = 20

    def __init__(self):
        self.rep_count: int = 0
        self.stage: str = "up"  # "up" / "down"

        # Low-pass filtered value (sumbu utama — az default untuk sensor di punggung)
        self._filtered_az: float | None = None

        # Timestamp transisi terakhir (untuk refractory)
        self._last_transition_time: float = 0.0

        # Buffer kecil untuk hitung jitter / stabilitas
        self._recent_accel: list[float] = []

    # ─── Public API ──────────────────────────────────────────────────────
    def update(self, sample: dict) -> dict:
        """
        Terima satu sample IMU, kembalikan status gerakan terkini.

        Parameters
        ----------
        sample : dict
            {"ax": float, "ay": float, "az": float,
             "gx": float, "gy": float, "gz": float}

        Returns
        -------
        dict  {"rep_count", "movement_status", "movement_issues"}
        """
        ax = sample.get("ax", 0.0)
        ay = sample.get("ay", 0.0)
        az = sample.get("az", 0.0)
        gx = sample.get("gx", 0.0)
        gy = sample.get("gy", 0.0)
        gz = sample.get("gz", 0.0)

        # --- low-pass filter pada az (sumbu vertikal utama) ---
        if self._filtered_az is None:
            self._filtered_az = az
        else:
            self._filtered_az += self.LPF_ALPHA * (az - self._filtered_az)

        filt = self._filtered_az

        # --- simpan ke jitter buffer ---
        self._recent_accel.append(filt)
        if len(self._recent_accel) > self.JITTER_WINDOW_SIZE:
            self._recent_accel.pop(0)

        # --- state machine: deteksi rep ---
        now = time.time()
        refractory_ok = (now - self._last_transition_time) >= self.REFRACTORY_SECONDS

        if self.stage == "up" and filt < self.ACCEL_DOWN_THRESHOLD and refractory_ok:
            self.stage = "down"
            self._last_transition_time = now
        elif self.stage == "down" and filt > self.ACCEL_UP_THRESHOLD and refractory_ok:
            self.stage = "up"
            self.rep_count += 1
            self._last_transition_time = now

        # --- evaluasi kualitas gerakan ---
        issues: list[str] = []

        # Cek kecepatan rotasi terlalu tinggi
        gyro_magnitude = math.sqrt(gx**2 + gy**2 + gz**2)
        if gyro_magnitude > self.GYRO_SPEED_LIMIT:
            issues.append("Gerakan terlalu cepat / hentakan terdeteksi")

        # Cek jitter / ketidakstabilan
        if len(self._recent_accel) >= self.JITTER_WINDOW_SIZE:
            mean_a = sum(self._recent_accel) / len(self._recent_accel)
            variance = sum((v - mean_a) ** 2 for v in self._recent_accel) / len(self._recent_accel)
            std_a = math.sqrt(variance)
            if std_a > self.ACCEL_JITTER_LIMIT:
                issues.append("Gerakan tidak stabil — coba lebih terkontrol")

        status = "good" if not issues else "bad"
        # Belum cukup data → unknown
        if len(self._recent_accel) < self.JITTER_WINDOW_SIZE // 2:
            status = "unknown"

        return {
            "rep_count": self.rep_count,
            "movement_status": status,
            "movement_issues": issues,
        }
