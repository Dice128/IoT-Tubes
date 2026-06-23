/*
  esp32_mpu6050_sender.ino
  ------------------------------------------------------
  Firmware ESP32 Dev Module + MPU6050/MPU6500 untuk push-up tracker.

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

  // [DIUBAH] Wiring I2C untuk ESP32 Dev Module (pakai pin I2C default):
    Sensor VCC -> 3V3
    Sensor GND -> GND
    Sensor SCL -> GPIO22   <-- pin SCL default ESP32
    Sensor SDA -> GPIO21   <-- pin SDA default ESP32
    Sensor AD0 -> GND (alamat I2C default 0x68)
*/

#include <Wire.h>
#include <WiFi.h>
#include <WebSocketsClient.h>
#include <ArduinoJson.h>

// [TAMBAHAN] Disable brownout detector untuk stabilitas di baterai
#include "soc/soc.h"
#include "soc/rtc_cntl_reg.h"
#include <esp_wifi.h>

// ---------- KONFIGURASI - SESUAIKAN BAGIAN INI ----------
const char* WIFI_SSID      = "RAE";
const char* WIFI_PASSWORD  = "jurgenklopp";
const char* SERVER_HOST    = "192.168.1.2";
const uint16_t SERVER_PORT = 8000;
const char* WS_PATH        = "/ws/esp32";

// [DIUBAH] 75ms (13Hz) — kompromi antara hemat power dan responsivitas
// Masalah power sudah teratasi dengan konektor langsung (bypass breadboard)
const unsigned long SEND_INTERVAL_MS = 75;

// Menyesuaikan dengan kabel di foto Anda (SDA=21, SCL=22)
const int I2C_SDA = 21;
const int I2C_SCL = 22;
// ----------------------------------------------------------

// ---------- Register & konstanta MPU6050/MPU6500 ----------
const uint8_t MPU_ADDR          = 0x68;
const uint8_t REG_WHO_AM_I      = 0x75;
const uint8_t REG_PWR_MGMT_1    = 0x6B;
const uint8_t REG_CONFIG        = 0x1A;
const uint8_t REG_GYRO_CONFIG   = 0x1B;
const uint8_t REG_ACCEL_CONFIG  = 0x1C;
const uint8_t REG_ACCEL_XOUT_H  = 0x3B;

const float ACCEL_SENS_LSB_PER_G   = 4096.0f;
const float GYRO_SENS_LSB_PER_DPS  = 65.5f;
const float G_TO_MS2   = 9.80665f;
// ------------------------------------------------------------

WebSocketsClient webSocket;

unsigned long lastSendTime = 0;
bool wsConnected = false;
bool sensorReady = false;

// Retry sensor init
const int SENSOR_MAX_RETRIES = 5;
const unsigned long SENSOR_RETRY_INTERVAL_MS = 5000; // coba ulang tiap 5 detik
unsigned long lastSensorRetryTime = 0;

// ---------- State Machine & Rep Counting Variables ----------
int repCount = 0;
bool isStageUp = true;
float filteredAz = 0.0;
unsigned long lastTransitionTime = 0;
bool pushupReady = false;
unsigned long lastCheckpointTime = 0;

const float LPF_ALPHA = 0.25;
const float ACCEL_UP_THRESHOLD = 10.8;
const float ACCEL_DOWN_THRESHOLD = 9.0;
const unsigned long REFRACTORY_MS = 500;
const unsigned long CHECKPOINT_TIMEOUT_MS = 3000;
// ------------------------------------------------------------

bool mpuWriteReg(uint8_t reg, uint8_t val) {
  Wire.beginTransmission(MPU_ADDR);
  Wire.write(reg);
  Wire.write(val);
  return Wire.endTransmission() == 0;
}

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

  if (!mpuWriteReg(REG_PWR_MGMT_1, 0x00)) return false;
  delay(50);

  mpuWriteReg(REG_CONFIG, 0x04);
  mpuWriteReg(REG_GYRO_CONFIG, 0x08);
  mpuWriteReg(REG_ACCEL_CONFIG, 0x10);

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
  Wire.read(); Wire.read();
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

// Fungsi untuk melepaskan I2C bus yang nyangkut (SDA low)
void recoverI2C() {
  pinMode(I2C_SDA, OUTPUT);
  pinMode(I2C_SCL, OUTPUT);
  digitalWrite(I2C_SDA, HIGH);
  digitalWrite(I2C_SCL, HIGH);
  for (int i = 0; i < 9; i++) {
    digitalWrite(I2C_SCL, LOW);
    delayMicroseconds(5);
    digitalWrite(I2C_SCL, HIGH);
    delayMicroseconds(5);
  }
  // Kembalikan ke mode default
  pinMode(I2C_SDA, INPUT_PULLUP);
  pinMode(I2C_SCL, INPUT_PULLUP);
  delay(10);
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
  // [TAMBAHAN] Disable brownout detector — mencegah ESP32 reset
  // saat arus spike dari WiFi TX pada supply baterai
  WRITE_PERI_REG(RTC_CNTL_BROWN_OUT_REG, 0);

  Serial.begin(115200);
  delay(200);
  Serial.println("Booting...");

  // Delay lebih lama agar power dari baterai+MT3608 stabil dulu
  Serial.println("Menunggu power stabil (2 detik)...");
  delay(2000);

  // Recovery I2C bus jika sensor hang akibat power drop sebelumnya
  recoverI2C();

  // Memulai I2C dengan pin yang sesuai dengan kabel Anda
  Wire.begin(I2C_SDA, I2C_SCL);

  // Coba init sensor beberapa kali (power dari baterai bisa tidak stabil)
  for (int attempt = 1; attempt <= SENSOR_MAX_RETRIES; attempt++) {
    Serial.printf("Init sensor - percobaan %d/%d...\n", attempt, SENSOR_MAX_RETRIES);
    if (mpuInit()) {
      sensorReady = true;
      Serial.println("Sensor siap dipakai!");
      break;
    }
    Serial.println("Sensor belum terdeteksi, coba lagi...");
    delay(1000);  // tunggu 1 detik sebelum retry
  }

  if (!sensorReady) {
    Serial.println("⚠ Sensor gagal init setelah beberapa percobaan.");
    Serial.println("  WiFi & WebSocket tetap jalan, sensor akan dicoba ulang di loop.");
  }

  // Konek WiFi & WebSocket TERLEPAS dari status sensor
  connectWifi();

  // [TAMBAHAN] Turunkan TX power WiFi untuk kurangi spike arus
  // WIFI_POWER_15dBm (~56mW) cukup untuk jarak dekat 5-10 meter
  // Default adalah 19.5dBm (~80mW) yang butuh arus lebih besar
  esp_wifi_set_max_tx_power(60);  // satuan 0.25dBm, 60 = 15dBm
  Serial.println("WiFi TX power diturunkan ke 15dBm untuk hemat arus");

  // [TAMBAHAN] Tunggu power stabil setelah WiFi init sebelum WebSocket
  Serial.println("Menunggu stabilisasi setelah WiFi connect (2 detik)...");
  delay(2000);

  webSocket.begin(SERVER_HOST, SERVER_PORT, WS_PATH);
  webSocket.onEvent(onWsEvent);
  webSocket.setReconnectInterval(5000);  // [DIUBAH] dari 3s ke 5s, kurangi reconnect spam
}

void loop() {
  webSocket.loop();

  if (WiFi.status() != WL_CONNECTED) {
    connectWifi();
    return;
  }

  unsigned long now = millis();

  // Jika sensor belum ready, coba init ulang secara berkala
  if (!sensorReady) {
    if (now - lastSensorRetryTime >= SENSOR_RETRY_INTERVAL_MS) {
      lastSensorRetryTime = now;
      Serial.println("Mencoba init sensor ulang...");
      recoverI2C();  // bebaskan bus sebelum mulai ulang
      Wire.begin(I2C_SDA, I2C_SCL);  // re-init I2C bus
      if (mpuInit()) {
        sensorReady = true;
        Serial.println("Sensor berhasil terdeteksi!");
      } else {
        Serial.println("Sensor masih belum terdeteksi.");
      }
    }
    return;  // skip kirim data kalau sensor belum ready
  }

  if (now - lastSendTime >= SEND_INTERVAL_MS) {
    lastSendTime = now;
    sendImuData();
  }
}

int sensorFailCount = 0;  // counter gagal baca sensor berturut-turut

void sendImuData() {
  int16_t rawAx, rawAy, rawAz, rawGx, rawGy, rawGz;
  if (!mpuReadRaw(&rawAx, &rawAy, &rawAz, &rawGx, &rawGy, &rawGz)) {
    Serial.println("Gagal baca data dari sensor");
    sensorFailCount++;
    if (sensorFailCount >= 10) {
      Serial.println("⚠ Sensor gagal baca 10x berturut - akan dicoba re-init");
      sensorReady = false;
      sensorFailCount = 0;
    }
    return;
  }
  sensorFailCount = 0;  // reset counter kalau berhasil baca

  unsigned long now = millis();
  float ax_ms2 = (rawAx / ACCEL_SENS_LSB_PER_G) * G_TO_MS2;
  float ay_ms2 = (rawAy / ACCEL_SENS_LSB_PER_G) * G_TO_MS2;
  float az_ms2 = (rawAz / ACCEL_SENS_LSB_PER_G) * G_TO_MS2;
  float gx_rad = (rawGx / GYRO_SENS_LSB_PER_DPS) * DEG_TO_RAD;
  float gy_rad = (rawGy / GYRO_SENS_LSB_PER_DPS) * DEG_TO_RAD;
  float gz_rad = (rawGz / GYRO_SENS_LSB_PER_DPS) * DEG_TO_RAD;

  if (filteredAz == 0.0) {
    filteredAz = az_ms2;
  } else {
    filteredAz += LPF_ALPHA * (az_ms2 - filteredAz);
  }

  if (now - lastCheckpointTime > CHECKPOINT_TIMEOUT_MS) {
    pushupReady = false;
  }

  bool refractoryOk = (now - lastTransitionTime) >= REFRACTORY_MS;

  if (isStageUp && filteredAz < ACCEL_DOWN_THRESHOLD && refractoryOk) {
    if (pushupReady) {
      isStageUp = false;
      lastTransitionTime = now;
    }
  } else if (!isStageUp && filteredAz > ACCEL_UP_THRESHOLD && refractoryOk) {
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

  Serial.println(buffer);

  if (wsConnected) {
    webSocket.sendTXT(buffer, len);
  }
}