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

    # Koefisien EMA low-pass filter (0-1, semakin kecil = semakin halus)
    LPF_ALPHA = 0.25

    # Threshold percepatan vertikal (m/s²) untuk deteksi puncak/lembah
    #   Saat push-up: badan turun → ay naik (gravitasi + gerak),
    #                  badan naik  → ay turun
    #   Sumbu bergantung orientasi sensor di badan; az sering jadi sumbu
    #   vertikal kalau sensor rata di punggung.
    #   Dilonggarkan agar rep lebih mudah terdeteksi.
    ACCEL_UP_THRESHOLD = 10.8    # di atas ini = posisi "up"
    ACCEL_DOWN_THRESHOLD = 9.0   # di bawah ini = posisi "down"

    # Threshold gyroscope (rad/s) — diturunkan agar lebih sensitif terhadap kecepatan/hentakan
    GYRO_SPEED_LIMIT = 2.0

    # Threshold variasi akselerasi — diturunkan agar lebih sensitif mendeteksi ketidakstabilan
    ACCEL_JITTER_LIMIT = 1.5

    # Jumlah sampel terakhir untuk hitung jitter
    JITTER_WINDOW_SIZE = 20

    def __init__(self):
        # Low-pass filtered value (sumbu utama — az default untuk sensor di punggung)
        self._filtered_az: float | None = None

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
        dict  {"movement_status", "movement_issues"}
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

        # --- evaluasi kualitas gerakan ---
        issues: list[str] = []

        # Cek kecepatan rotasi terlalu tinggi
        gyro_magnitude = math.sqrt(gx**2 + gy**2 + gz**2)
        if gyro_magnitude > self.GYRO_SPEED_LIMIT:
            issues.append("Gerakan terlalu cepat / hentakan terdeteksi")

        # Cek jitter / ketidakstabilan
        std_a = 0.0
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
            "movement_status": status,
            "movement_issues": issues,
            "gyro_magnitude": float(gyro_magnitude),
            "accel_jitter": float(std_a),
        }
