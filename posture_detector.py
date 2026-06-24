"""
posture_detector.py

Modul rule-based untuk menilai postur push-up dari webcam menggunakan MediaPipe Pose Tasks API.
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
"""

import math
import cv2
import numpy as np
import mediapipe as mp
from mediapipe.tasks import python
from mediapipe.tasks.python import vision

# Landmark indices
LEFT_SHOULDER = 11
RIGHT_SHOULDER = 12
LEFT_ELBOW = 13
RIGHT_ELBOW = 14
LEFT_WRIST = 15
RIGHT_WRIST = 16
LEFT_HIP = 23
RIGHT_HIP = 24
LEFT_KNEE = 25
RIGHT_KNEE = 26
LEFT_ANKLE = 27
RIGHT_ANKLE = 28

POSE_CONNECTIONS = [
    (11, 12), (11, 13), (13, 15), (12, 14), (14, 16),
    (11, 23), (12, 24), (23, 24), (23, 25), (24, 26),
    (25, 27), (26, 28)
]

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
    # Threshold — dilonggarkan agar rep tetap terhitung meski tidak 100% sempurna.
    HIP_SAG_THRESHOLD = 0.10
    HIP_PIKE_THRESHOLD = 0.10
    DEPTH_ELBOW_ANGLE = 110     # sudut siku harus turun di bawah ini agar dianggap rep penuh
    TOP_ELBOW_ANGLE = 150       # sudut siku di atas ini dianggap posisi atas

    def __init__(self, min_detection_confidence=0.6, min_tracking_confidence=0.6):
        import os
        model_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'pose_landmarker_heavy.task')
        base_options = python.BaseOptions(model_asset_path=model_path)
        options = vision.PoseLandmarkerOptions(
            base_options=base_options,
            output_segmentation_masks=False,
            min_pose_detection_confidence=min_detection_confidence,
            min_pose_presence_confidence=0.6,
            min_tracking_confidence=min_tracking_confidence,
        )
        self.detector = vision.PoseLandmarker.create_from_options(options)

    def _pick_side(self, lm):
        """Pilih sisi tubuh (kiri/kanan) dengan visibility rata-rata lebih tinggi di kamera."""
        left_points = [LEFT_SHOULDER, LEFT_ELBOW, LEFT_WRIST, LEFT_HIP, LEFT_KNEE, LEFT_ANKLE]
        right_points = [RIGHT_SHOULDER, RIGHT_ELBOW, RIGHT_WRIST, RIGHT_HIP, RIGHT_KNEE, RIGHT_ANKLE]

        left_vis = np.mean([lm[p].visibility for p in left_points])
        right_vis = np.mean([lm[p].visibility for p in right_points])
        return left_points if left_vis >= right_vis else right_points

    def draw_landmarks(self, image, landmarks):
        """Gambar landmark dan koneksi secara manual."""
        h, w = image.shape[:2]
        
        # Gambar garis
        for connection in POSE_CONNECTIONS:
            idx1, idx2 = connection
            if idx1 < len(landmarks) and idx2 < len(landmarks):
                lm1 = landmarks[idx1]
                lm2 = landmarks[idx2]
                if lm1.visibility > 0.5 and lm2.visibility > 0.5:
                    pt1 = (int(lm1.x * w), int(lm1.y * h))
                    pt2 = (int(lm2.x * w), int(lm2.y * h))
                    cv2.line(image, pt1, pt2, (255, 255, 255), 2)
                    
        # Gambar titik
        for idx, lm in enumerate(landmarks):
            if lm.visibility > 0.5:
                pt = (int(lm.x * w), int(lm.y * h))
                cv2.circle(image, pt, 4, (0, 0, 255), -1)

    def analyze(self, frame_bgr):
        """
        Input: frame BGR (dari cv2.VideoCapture).
        Output: (result_dict, annotated_frame)
        """
        frame_rgb = cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2RGB)
        mp_image = mp.Image(image_format=mp.ImageFormat.SRGB, data=frame_rgb)
        detection_result = self.detector.detect(mp_image)

        result = {
            "pose_detected": False,
            "status": "unknown",
            "issues": [],
            "elbow_angle": None,
            "hip_deviation": None,
            "in_pushup_position": False,
            "rep_quality": "perfect",
        }

        if not detection_result.pose_landmarks:
            return result, frame_bgr

        lm = detection_result.pose_landmarks[0] # Ambil orang pertama
        h, w = frame_bgr.shape[:2]
        
        shoulder_p, elbow_p, wrist_p, hip_p, knee_p, ankle_p = self._pick_side(lm)

        def pt(index):
            point = lm[index]
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
            "rep_quality": "perfect" if not issues else "imperfect",
        })

        annotated = frame_bgr.copy()
        self.draw_landmarks(annotated, lm)
        
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
