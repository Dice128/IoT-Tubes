import cv2
import serial
import csv
import time
from ultralytics import YOLO

# --- SETUP SERIAL ESP32 ---
esp32_port = 'COM6' 
baud_rate = 115200
try:
    ser = serial.Serial(esp32_port, baud_rate, timeout=0.05)
    print(f"Berhasil terhubung ke ESP32 di {esp32_port}")
except Exception as e:
    print(f"Gagal terhubung ke ESP32: {e}")
    ser = None

# --- SETUP CSV LOGGING (Langkah 1) ---
csv_filename = 'data_gerakan_hybrid.csv'
# Membuat file CSV baru dan menulis judul kolom (header)
with open(csv_filename, mode='w', newline='') as file:
    writer = csv.writer(file)
    writer.writerow(['Waktu', 'Acc_X', 'Acc_Y', 'Acc_Z', 'Gyro_X', 'Gyro_Y', 'Gyro_Z', 'Posisi_Bahu_Y', 'Posisi_Siku_Y', 'Posisi_Pergelangan_Y', 'Status_Gerakan'])
print(f"File log {csv_filename} berhasil dibuat.")

# --- SETUP YOLO ---
model = YOLO('yolov8n-pose.pt')
cap = cv2.VideoCapture(0)

print("Membuka webcam... Tekan 'q' untuk keluar.")

# Variabel sementara untuk menyimpan data sensor terakhir
ax = ay = az = gx = gy = gz = 0.0
sensor_text = "Menunggu data sensor..."

while cap.isOpened():
    ret, frame = cap.read()
    if not ret:
        break

    # --- BACA DATA DARI ESP32 ---
    if ser is not None and ser.in_waiting > 0:
        try:
            line = ser.readline().decode('utf-8', errors='ignore').strip()
            if line:
                data = line.split(',')
                if len(data) == 6:
                    ax, ay, az, gx, gy, gz = map(float, data)
                    sensor_text = f"Acc(Z): {az:.2f} | Gyro(Y): {gy:.2f}"
        except Exception:
            pass # Abaikan jika ada data terpotong

    # --- PROSES DETEKSI YOLO ---
    results = model(frame, stream=True, verbose=False)
    
    # Nilai default jika orang tidak terdeteksi
    status_gerakan = "Menunggu subjek..."
    bahu_y = siku_y = pergelangan_y = 0.0
    warna_teks = (255, 255, 255) # Putih

    for r in results:
        frame = r.plot()
        keypoints = r.keypoints
        
        if keypoints is not None and keypoints.xy.shape[1] > 0:
            try:
                # Index YOLO: 6 = Bahu Kanan, 8 = Siku Kanan, 10 = Pergelangan Kanan
                bahu_kanan = keypoints.xy[0][6]
                siku_kanan = keypoints.xy[0][8] 
                pergelangan_kanan = keypoints.xy[0][10]
                
                # Mengambil nilai Y (tinggi/rendah posisi di layar)
                bahu_y = bahu_kanan[1].item()
                siku_y = siku_kanan[1].item()
                pergelangan_y = pergelangan_kanan[1].item()
                
                if bahu_y > 0 and siku_y > 0 and pergelangan_y > 0:
                    # --- EVALUASI GERAKAN (Langkah 3) ---
                    # Catatan: Di OpenCV, titik Y=0 ada di atas layar. 
                    # Jadi nilai Y lebih kecil berarti posisinya lebih tinggi secara fisik.
                    tangan_diangkat = pergelangan_y < siku_y and siku_y < bahu_y
                    
                    # Konversi kembali nilai rad/s dari ESP32 menjadi deg/s
                    gx_deg = gx * 57.2958
                    gz_deg = gz * 57.2958
                    
                    # Rumus kecepatan ayunan
                    kecepatan_ayunan = abs(gx_deg) + abs(gz_deg)
                    threshold_smash = 40.0
                    
                    if tangan_diangkat:
                        if kecepatan_ayunan > threshold_smash:
                            status_gerakan = "SMASH SEMPURNA!"
                            warna_teks = (0, 255, 0) # Hijau
                        else:
                            status_gerakan = "Posisi OK, siap memukul"
                            warna_teks = (0, 255, 255) # Kuning
                    else:
                        if kecepatan_ayunan > threshold_smash:
                            status_gerakan = "POSTUR SALAH! Angkat tangan!"
                            warna_teks = (0, 0, 255) # Merah
                        else:
                            status_gerakan = "Persiapan..."
                            warna_teks = (255, 255, 255) # Putih

            except IndexError:
                pass 

    # --- SIMPAN DATA KE CSV (Langkah 1) ---
    # Mencatat semua variabel ke file CSV setiap frame video berjalan
    with open(csv_filename, mode='a', newline='') as file:
        writer = csv.writer(file)
        waktu_sekarang = time.strftime("%H:%M:%S")
        writer.writerow([waktu_sekarang, ax, ay, az, gx, gy, gz, bahu_y, siku_y, pergelangan_y, status_gerakan])

    # --- FUSI VISUAL KE LAYAR ---
    cv2.putText(frame, "Sensor MPU6050:", (10, 30), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (255, 200, 0), 2)
    cv2.putText(frame, sensor_text, (10, 60), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (255, 200, 0), 2)
    
    # Menampilkan hasil evaluasi sistem hybrid
    cv2.putText(frame, f"Evaluasi: {status_gerakan}", (10, 95), cv2.FONT_HERSHEY_SIMPLEX, 0.8, warna_teks, 2)

    cv2.imshow('IoT-Vision Hybrid System', frame)

    if cv2.waitKey(1) & 0xFF == ord('q'):
        break

# Bersihkan resource
cap.release()
if ser is not None:
    ser.close()
cv2.destroyAllWindows()