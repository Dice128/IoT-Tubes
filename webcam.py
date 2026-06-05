import cv2
from ultralytics import YOLO

# Load model YOLO pose versi 'nano' (sangat ringan untuk Edge Computing)
# Model akan otomatis diunduh saat pertama kali dijalankan
model = YOLO('yolov8n-pose.pt')

# Buka Webcam (0 adalah default kamera laptop)
cap = cv2.VideoCapture(0)

print("Membuka webcam dengan YOLOv8 Pose... Tekan 'q' untuk keluar.")

while cap.isOpened():
    ret, frame = cap.read()
    if not ret:
        print("Gagal membaca frame dari webcam.")
        break

    # Proses deteksi pose dengan YOLO
    # stream=True membuat pemrosesan real-time lebih efisien
    # verbose=False mematikan log teks di terminal agar tidak berisik
    results = model(frame, stream=True, verbose=False)

    for r in results:
        # Menggambar skeleton bawaan YOLO langsung ke frame
        frame = r.plot()
        
        # --- PERSIAPAN UNTUK FUSI DATA (SENSOR FUSION) DENGAN ESP32 ---
        keypoints = r.keypoints
        
        # Pastikan ada orang yang terdeteksi
        if keypoints is not None and keypoints.xy.shape[1] > 0:
            # YOLOv8 mendeteksi 17 keypoints. 
            # Index ke-8 adalah siku kanan (Right Elbow).
            # xy[0] berarti kita mengambil data dari orang pertama yang terdeteksi.
            try:
                right_elbow = keypoints.xy[0][8] 
                x, y = right_elbow[0].item(), right_elbow[1].item()
                
                # Jika koordinat valid (tidak 0), kita bisa gunakan datanya
                if x > 0 and y > 0:
                    # Menambahkan lingkaran biru tebal di siku kanan sebagai penanda khusus
                    cv2.circle(frame, (int(x), int(y)), 8, (255, 0, 0), -1)
                    
                    # Anda bisa menghapus tanda pagar di bawah ini untuk melihat nilainya
                    # print(f"Siku Kanan - X: {x:.2f}, Y: {y:.2f}")
            except IndexError:
                pass # Abaikan jika siku tertutup atau tidak terdeteksi

    # Tampilkan hasil video ke layar
    cv2.imshow('IoT-Vision Hybrid System (YOLO)', frame)

    # Tekan tombol 'q' untuk keluar dari loop video
    if cv2.waitKey(1) & 0xFF == ord('q'):
        break

# Bersihkan resource setelah selesai
cap.release()
cv2.destroyAllWindows()