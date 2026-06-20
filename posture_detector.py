"""
posture_detector.py

Modul rule-based untuk menilai postur push-up dari webcam menggunakan MediaPipe Pose.
Tidak butuh training - aturan/threshold ditentukan dari geometri sudut sendi.

Instalasi:
    pip install opencv-python mediapipe numpy

Jalankan langsung untuk testing di laptop (buka webcam, tampilkan overlay):
    python posture_detector.py

Untuk dipakai nanti di server (FastAPI dsb):
    from posture_detector import PostureDetector
    detector = PostureDetector()
    result, annotated_frame = detector.analyze(frame_bgr)
    # result adalah dict siap dikirim sebagai JSON ke mobile app

Catatan setup kamera: metode "hip deviation" di bawah paling akurat kalau
webcam mengambil tubuh dari SAMPING (side view), bukan dari depan.
"""

import math
import cv2
import numpy as np
import mediapipe as mp

mp_pose = mp.solutions.pose
mp_drawing = mp.solutions.drawing_utils


def calculate_angle(a, b, c):
    """Hitung sudut (derajat) di titik b, dibentuk oleh garis a-b dan c-b."""
    a, b, c = np.array(a), np.array(b), np.array(c)
    radians = (np.arctan2(c[1] - b[1], c[0] - b[0])
               - np.arctan2(a[1] - b[1], a[0] - b[0]))
    angle = np.abs(radians * 180.0 / np.pi)
    if angle > 180.0:
        angle = 360 - angle
    return angle


def line_deviation(shoulder, hip, ankle):
    """
    Hitung seberapa jauh titik pinggul (hip) menyimpang dari garis lurus
    bahu-tumit (shoulder-ankle), dinormalisasi terhadap panjang tubuh.
    Positif = pinggul turun (sagging), negatif = pinggul naik (piking).
    """
    sx, sy = shoulder
    hx, hy = hip
    ax, ay = ankle

    if ax == sx:
        expected_y = (sy + ay) / 2
    else:
        t = (hx - sx) / (ax - sx)
        expected_y = sy + t * (ay - sy)

    body_length = math.hypot(ax - sx, ay - sy)
    if body_length == 0:
        return 0.0
    return (hy - expected_y) / body_length


class PostureDetector:
    # Threshold awal - sesuaikan lagi setelah uji coba dengan kamera & posisi nyata
    HIP_SAG_THRESHOLD = 0.06
    HIP_PIKE_THRESHOLD = 0.06
    DEPTH_ELBOW_ANGLE = 100     # sudut siku harus turun di bawah ini agar dianggap rep penuh
    TOP_ELBOW_ANGLE = 155       # sudut siku di atas ini dianggap posisi atas (lengan lurus)

    def __init__(self, min_detection_confidence=0.6, min_tracking_confidence=0.6):
        self.pose = mp_pose.Pose(
            min_detection_confidence=min_detection_confidence,
            min_tracking_confidence=min_tracking_confidence,
        )

    def _pick_side(self, lm):
        """Pilih sisi tubuh (kiri/kanan) dengan visibility rata-rata lebih tinggi di kamera."""
        L = mp_pose.PoseLandmark
        left_points = [L.LEFT_SHOULDER, L.LEFT_ELBOW, L.LEFT_WRIST,
                       L.LEFT_HIP, L.LEFT_KNEE, L.LEFT_ANKLE]
        right_points = [L.RIGHT_SHOULDER, L.RIGHT_ELBOW, L.RIGHT_WRIST,
                        L.RIGHT_HIP, L.RIGHT_KNEE, L.RIGHT_ANKLE]

        left_vis = np.mean([lm[p.value].visibility for p in left_points])
        right_vis = np.mean([lm[p.value].visibility for p in right_points])
        return left_points if left_vis >= right_vis else right_points

    def analyze(self, frame_bgr):
        """
        Input: frame BGR (dari cv2.VideoCapture).
        Output: (result_dict, annotated_frame)
        result_dict siap di-serialize jadi JSON untuk dikirim ke mobile app.
        """
        frame_rgb = cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2RGB)
        results = self.pose.process(frame_rgb)

        result = {
            "pose_detected": False,
            "status": "unknown",
            "issues": [],
            "elbow_angle": None,
            "hip_deviation": None,
            "in_pushup_position": False,
        }

        if not results.pose_landmarks:
            return result, frame_bgr

        lm = results.pose_landmarks.landmark
        h, w = frame_bgr.shape[:2]
        shoulder_p, elbow_p, wrist_p, hip_p, knee_p, ankle_p = self._pick_side(lm)

        def pt(landmark):
            point = lm[landmark.value]
            return [point.x * w, point.y * h]

        shoulder, elbow, wrist = pt(shoulder_p), pt(elbow_p), pt(wrist_p)
        hip, knee, ankle = pt(hip_p), pt(knee_p), pt(ankle_p)

        elbow_angle = calculate_angle(shoulder, elbow, wrist)
        hip_dev = line_deviation(shoulder, hip, ankle)

        issues = []
        if hip_dev > self.HIP_SAG_THRESHOLD:
            issues.append("Pinggul turun - tahan badan tetap lurus")
        elif hip_dev < -self.HIP_PIKE_THRESHOLD:
            issues.append("Pinggul terlalu naik - sejajarkan dengan bahu dan tumit")

        status = "good" if not issues else "bad"
        in_pushup_position = (status == "good") and (elbow_angle > 140.0)

        result.update({
            "pose_detected": True,
            "status": status,
            "issues": issues,
            "elbow_angle": round(float(elbow_angle), 1),
            "hip_deviation": round(float(hip_dev), 3),
            "in_pushup_position": in_pushup_position,
        })

        annotated = frame_bgr.copy()
        mp_drawing.draw_landmarks(annotated, results.pose_landmarks, mp_pose.POSE_CONNECTIONS)
        color = (0, 200, 0) if status == "good" else (0, 0, 220)
        cv2.putText(annotated, f"Status: {status.upper()}", (20, 40),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.9, color, 2)
        cv2.putText(annotated, f"Elbow: {elbow_angle:.0f} deg  Hip dev: {hip_dev:.3f}",
                    (20, 70), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (255, 255, 255), 1)
        cv2.putText(annotated, f"Ready: {in_pushup_position}", (20, 100),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.7, (255, 255, 0), 2)
        for i, issue in enumerate(issues):
            cv2.putText(annotated, issue, (20, 130 + i * 25),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 0, 220), 2)

        return result, annotated


def main():
    cap = cv2.VideoCapture(0)
    detector = PostureDetector()

    if not cap.isOpened():
        print("Tidak bisa akses webcam")
        return

    print("Tekan 'q' untuk keluar")
    while cap.isOpened():
        ok, frame = cap.read()
        if not ok:
            break

        result, annotated = detector.analyze(frame)
        cv2.imshow("Push-up Posture Detector", annotated)

        if cv2.waitKey(1) & 0xFF == ord("q"):
            break

    cap.release()
    cv2.destroyAllWindows()


if __name__ == "__main__":
    main()
