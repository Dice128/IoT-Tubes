#include <Wire.h>

#define MPU 0x68
#define SMASH_THRESHOLD      40.0
#define SMASH_HARD_THRESHOLD 70.0
#define ROLL_MIN            -50.0
#define ROLL_MAX            -25.0
#define COOLDOWN_MS          1000

unsigned long lastSmashTime = 0;
int smashCount = 0;

void setup() {
  Serial.begin(115200);
  Wire.begin(23, 22);

  Wire.beginTransmission(MPU);
  Wire.write(0x6B);
  Wire.write(0x00);
  Wire.endTransmission(true);

  Serial.println("=== Badminton Smash Detector ===");
  Serial.println("Pasang sensor di lengan atas.");
  Serial.println("Siap mendeteksi gerakan smash...");
  Serial.println("================================");
}

void loop() {
  Wire.beginTransmission(MPU);
  Wire.write(0x3B);
  Wire.endTransmission(false);
  Wire.requestFrom(MPU, 14, true);

  int16_t ax = Wire.read() << 8 | Wire.read();
  int16_t ay = Wire.read() << 8 | Wire.read();
  int16_t az = Wire.read() << 8 | Wire.read();
  Wire.read(); Wire.read();
  int16_t gx = Wire.read() << 8 | Wire.read();
  int16_t gy = Wire.read() << 8 | Wire.read();
  int16_t gz = Wire.read() << 8 | Wire.read();

  float AX = ax / 16384.0;
  float AY = ay / 16384.0;
  float AZ = az / 16384.0;
  float GX = gx / 131.0;
  float GZ = gz / 131.0;

  float pitch = atan2(AY, sqrt(AX*AX + AZ*AZ)) * 180.0 / PI;
  float roll  = atan2(-AX, AZ) * 180.0 / PI;

  float speed = abs(GX) + abs(GZ);
  unsigned long now = millis();
  bool cooldownOk = (now - lastSmashTime) > COOLDOWN_MS;

  if (speed > SMASH_THRESHOLD && cooldownOk) {
    lastSmashTime = now;
    smashCount++;

    Serial.println();
    if (speed > SMASH_HARD_THRESHOLD) {
      Serial.print("[SMASH KERAS #");
    } else {
      Serial.print("[SMASH #");
    }
    Serial.print(smashCount);
    Serial.print("] Kecepatan: ");
    Serial.print(speed, 1);
    Serial.print(" deg/s | Pitch: ");
    Serial.print(pitch, 1);
    Serial.print("° Roll: ");
    Serial.print(roll, 1);
    Serial.print("°");

    if (roll >= ROLL_MIN && roll <= ROLL_MAX) {
      Serial.println(" >> POSTUR OK");
    } else {
      Serial.println(" >> PERBAIKI POSTUR!");
    }
    Serial.println();

  } else if (speed <= SMASH_THRESHOLD) {
    Serial.print("Siap... Pitch:");
    Serial.print(pitch, 1);
    Serial.print("° Roll:");
    Serial.print(roll, 1);
    Serial.print("° Speed:");
    Serial.println(speed, 1);
  }

  delay(50);
}