/*
  esp32_mpu6050_sender.ino
  ------------------------------------------------------
  Firmware ESP32 Lolin + MPU6050/MPU6500 untuk push-up tracker.

  Tugas firmware ini HANYA:
  1. Baca data accelerometer & gyroscope dari sensor (I2C)
  2. Kirim data ke server (laptop) lewat WebSocket, format JSON

  Pemrosesan gerakan (deteksi rep, validasi gerakan benar/salah)
  sengaja TIDAK dilakukan di sini - itu tugas server laptop, supaya
  logikanya gampang diubah tanpa harus re-flash ESP32 tiap kali.

  CATATAN PENTING (revisi):
  Modul yang dipakai ternyata chipnya MPU-6500 (WHO_AM_I = 0x70),
  bukan MPU-6050 asli (WHO_AM_I = 0x68) - umum terjadi di modul
  GY-521 murah yang dilabel "MPU6050". Library Adafruit_MPU6050
  selalu menolak chip ini karena ada pengecekan ID chip yang ketat,
  padahal secara register accel/gyro, MPU-6500 kompatibel dengan
  MPU-6050. Jadi versi ini TIDAK pakai library Adafruit sama sekali,
  melainkan baca register I2C langsung - otomatis jalan baik di
  chip MPU6050 asli maupun MPU6500 clone.

  Library yang perlu di-install lewat Library Manager Arduino IDE:
    - ArduinoJson        (by Benoit Blanchon)
    - WebSockets         (by Markus Sattler / Links2004)
  (Adafruit MPU6050 / Adafruit Unified Sensor / Adafruit BusIO TIDAK
   dibutuhkan lagi di versi ini.)

  Wiring I2C (KHUSUS Lolin32 Lite - board ini TIDAK punya pin GPIO21,
  dan GPIO22 sudah dipakai untuk LED onboard, jadi pin I2C dipindah manual):
    Sensor VCC -> 3V3
    Sensor GND -> GND
    Sensor SCL -> GPIO19
    Sensor SDA -> GPIO23
    Sensor AD0 -> GND (alamat I2C default 0x68)
*/

#include <Wire.h>
#include <WiFi.h>
#include <WebSocketsClient.h>
#include <ArduinoJson.h>

// ---------- KONFIGURASI - SESUAIKAN BAGIAN INI ----------
const char* WIFI_SSID      = "Asalole 4G";
const char* WIFI_PASSWORD  = "21032006";
const char* SERVER_HOST    = "192.168.18.74";   // IP laptop di jaringan WiFi yang sama
const uint16_t SERVER_PORT = 8000;
const char* WS_PATH        = "/ws/esp32";

const unsigned long SEND_INTERVAL_MS = 50;      // ~20Hz, cukup untuk gerakan push-up
// ----------------------------------------------------------

// ---------- Register & konstanta MPU6050/MPU6500 ----------
const uint8_t MPU_ADDR          = 0x68;
const uint8_t REG_WHO_AM_I      = 0x75;
const uint8_t REG_PWR_MGMT_1    = 0x6B;
const uint8_t REG_CONFIG        = 0x1A;
const uint8_t REG_GYRO_CONFIG   = 0x1B;
const uint8_t REG_ACCEL_CONFIG  = 0x1C;
const uint8_t REG_ACCEL_XOUT_H  = 0x3B;

// Sesuai setting di bawah: accel +-8g, gyro +-500 deg/s
const float ACCEL_SENS_LSB_PER_G   = 4096.0f;   // AFS_SEL=2 (+-8g)
const float GYRO_SENS_LSB_PER_DPS  = 65.5f;     // FS_SEL=1  (+-500 dps)
const float G_TO_MS2   = 9.80665f;
// DEG_TO_RAD TIDAK didefinisikan ulang di sini - core ESP32 (Arduino.h) sudah
// punya macro DEG_TO_RAD bawaan dengan nilai yang sama, dan mendefinisikannya
// ulang di sini menyebabkan error compile (macro itu menimpa nama variabel kita).
// ------------------------------------------------------------

WebSocketsClient webSocket;

unsigned long lastSendTime = 0;
bool wsConnected = false;

// ---------- State Machine & Rep Counting Variables ----------
int repCount = 0;
bool isStageUp = true;
float filteredAz = 0.0;
unsigned long lastTransitionTime = 0;
bool pushupReady = false;
unsigned long lastCheckpointTime = 0;

// Konstanta untuk rep detection (hasil kalibrasi)
const float LPF_ALPHA = 0.25;
const float ACCEL_UP_THRESHOLD = 11.5;
const float ACCEL_DOWN_THRESHOLD = 8.5;
const unsigned long REFRACTORY_MS = 600;
const unsigned long CHECKPOINT_TIMEOUT_MS = 3000;
// ------------------------------------------------------------

bool mpuWriteReg(uint8_t reg, uint8_t val) {
  Wire.beginTransmission(MPU_ADDR);
  Wire.write(reg);
  Wire.write(val);
  return Wire.endTransmission() == 0;
}

// Mengembalikan true kalau chip terdeteksi sebagai MPU6050 (0x68) ATAU MPU6500 (0x70)
bool mpuDetect() {
  Wire.beginTransmission(MPU_ADDR);
  Wire.write(REG_WHO_AM_I);
  if (Wire.endTransmission(false) != 0) return false;

  if (Wire.requestFrom((int)MPU_ADDR, 1) != 1) return false;
  uint8_t whoAmI = Wire.read();

  if (whoAmI == 0x68) {
    Serial.println("Chip terdeteksi: MPU-6050/6000/9150 asli (0x68)");
    return true;
  } else if (whoAmI == 0x70) {
    Serial.println("Chip terdeteksi: MPU-6500/9250 (0x70) - mode kompatibel aktif");
    return true;
  }

  Serial.print("WHO_AM_I tidak dikenal: 0x");
  Serial.println(whoAmI, HEX);
  return false;
}

bool mpuInit() {
  if (!mpuDetect()) return false;

  if (!mpuWriteReg(REG_PWR_MGMT_1, 0x00)) return false;  // wake up dari sleep mode
  delay(50);

  mpuWriteReg(REG_CONFIG, 0x04);        // DLPF ~20-21Hz
  mpuWriteReg(REG_GYRO_CONFIG, 0x08);   // FS_SEL=1  -> +-500 deg/s
  mpuWriteReg(REG_ACCEL_CONFIG, 0x10);  // AFS_SEL=2 -> +-8g

  return true;
}

bool mpuReadRaw(int16_t* ax, int16_t* ay, int16_t* az,
                int16_t* gx, int16_t* gy, int16_t* gz) {
  Wire.beginTransmission(MPU_ADDR);
  Wire.write(REG_ACCEL_XOUT_H);
  if (Wire.endTransmission(false) != 0) return false;

  if (Wire.requestFrom((int)MPU_ADDR, 14) != 14) return false;

  *ax = (int16_t)((Wire.read() << 8) | Wire.read());
  *ay = (int16_t)((Wire.read() << 8) | Wire.read());
  *az = (int16_t)((Wire.read() << 8) | Wire.read());
  Wire.read(); Wire.read();  // skip 2 byte data temperatur, tidak dipakai
  *gx = (int16_t)((Wire.read() << 8) | Wire.read());
  *gy = (int16_t)((Wire.read() << 8) | Wire.read());
  *gz = (int16_t)((Wire.read() << 8) | Wire.read());

  return true;
}

void onWsEvent(WStype_t type, uint8_t* payload, size_t length) {
  switch (type) {
    case WStype_CONNECTED:
      Serial.println("WebSocket tersambung ke server");
      wsConnected = true;
      break;
    case WStype_DISCONNECTED:
      Serial.println("WebSocket putus dari server");
      wsConnected = false;
      break;
    case WStype_TEXT: {
      StaticJsonDocument<200> doc;
      DeserializationError error = deserializeJson(doc, payload, length);
      if (!error) {
        if (doc.containsKey("pushup_ready")) {
          pushupReady = doc["pushup_ready"].as<bool>();
          lastCheckpointTime = millis();
        }
      }
      break;
    }
    case WStype_ERROR:
      Serial.println("WebSocket error");
      break;
    default:
      break;
  }
}

void connectWifi() {
  Serial.printf("Menghubungkan ke WiFi \"%s\"...\n", WIFI_SSID);
  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);

  while (WiFi.status() != WL_CONNECTED) {
    delay(300);
    Serial.print(".");
  }
  Serial.println();
  Serial.print("WiFi tersambung, IP ESP32: ");
  Serial.println(WiFi.localIP());
}

void setup() {
  Serial.begin(115200);
  delay(200);
  Serial.println("Booting...");

  Wire.setPins(23, 19);  // Lolin32 Lite: SDA=GPIO23, SCL=GPIO19 (GPIO21 tidak ada, GPIO22 dipakai LED onboard)
  Wire.begin();

  if (!mpuInit()) {
    Serial.println("Sensor tidak terdeteksi - cek wiring I2C!");
    while (true) {
      delay(1000);
    }
  }
  Serial.println("Sensor siap dipakai");

  connectWifi();

  webSocket.begin(SERVER_HOST, SERVER_PORT, WS_PATH);
  webSocket.onEvent(onWsEvent);
  webSocket.setReconnectInterval(3000);
}

void loop() {
  webSocket.loop();

  if (WiFi.status() != WL_CONNECTED) {
    connectWifi();
    return;
  }

  unsigned long now = millis();
  if (now - lastSendTime >= SEND_INTERVAL_MS) {
    lastSendTime = now;
    sendImuData();
  }
}

void sendImuData() {
  int16_t rawAx, rawAy, rawAz, rawGx, rawGy, rawGz;
  if (!mpuReadRaw(&rawAx, &rawAy, &rawAz, &rawGx, &rawGy, &rawGz)) {
    Serial.println("Gagal baca data dari sensor");
    return;
  }

  unsigned long now = millis();
  float ax_ms2 = (rawAx / ACCEL_SENS_LSB_PER_G) * G_TO_MS2;
  float ay_ms2 = (rawAy / ACCEL_SENS_LSB_PER_G) * G_TO_MS2;
  float az_ms2 = (rawAz / ACCEL_SENS_LSB_PER_G) * G_TO_MS2;
  float gx_rad = (rawGx / GYRO_SENS_LSB_PER_DPS) * DEG_TO_RAD;
  float gy_rad = (rawGy / GYRO_SENS_LSB_PER_DPS) * DEG_TO_RAD;
  float gz_rad = (rawGz / GYRO_SENS_LSB_PER_DPS) * DEG_TO_RAD;

  // --- Low-pass filter pada az (sumbu vertikal utama) ---
  if (filteredAz == 0.0) {
    filteredAz = az_ms2;
  } else {
    filteredAz += LPF_ALPHA * (az_ms2 - filteredAz);
  }

  // --- Cek fail-safe checkpoint ---
  if (now - lastCheckpointTime > CHECKPOINT_TIMEOUT_MS) {
    pushupReady = false;
  }

  // --- State machine: deteksi rep ---
  bool refractoryOk = (now - lastTransitionTime) >= REFRACTORY_MS;

  if (isStageUp && filteredAz < ACCEL_DOWN_THRESHOLD && refractoryOk) {
    // GATE CHECKPOINT: Hanya boleh turun (mulai rep) kalau vision mengonfirmasi posisi siap
    if (pushupReady) {
      isStageUp = false;
      lastTransitionTime = now;
    }
  } else if (!isStageUp && filteredAz > ACCEL_UP_THRESHOLD && refractoryOk) {
    // Kalau sudah turun, biarkan kembali naik (menyelesaikan rep) secara normal
    isStageUp = true;
    repCount++;
    lastTransitionTime = now;
  }

  StaticJsonDocument<200> doc;
  doc["ts"] = now;
  doc["ax"] = ax_ms2;
  doc["ay"] = ay_ms2;
  doc["az"] = az_ms2;
  doc["gx"] = gx_rad;
  doc["gy"] = gy_rad;
  doc["gz"] = gz_rad;
  doc["rep_count"] = repCount;

  char buffer[200];
  size_t len = serializeJson(doc, buffer);

  // Tetap di-print ke Serial supaya bisa dites sebelum server FastAPI jadi
  Serial.println(buffer);

  if (wsConnected) {
    webSocket.sendTXT(buffer, len);
  }
}
