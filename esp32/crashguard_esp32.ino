// ============================================================================
// CrashGuard ESP32 — Combined Firmware  (Production-Grade v2)
// ============================================================================
// Features:
//   1. BLE provisioning (receive WiFi creds + UID from Flutter app)
//   2. Non-blocking WiFi connection (no BLE timeout)
//   3. MPU6050 accident detection (impact → jerk → stillness pipeline)
//   4. Firebase RTDB accident reporting via REST API
//   5. Device heartbeat (online/offline status)
//   6. Persistent credentials (Preferences — survives reboot)
//   7. Auto-reconnect WiFi + auto-restart BLE advertising
//   8. Hardware watchdog (auto-resets if code hangs — no EN button needed)
//   9. Non-blocking buzzer alarm (WiFi stays alive during alerts)
//  10. Real Unix timestamps via NTP (not millis())
//  11. Offline status write on WiFi disconnect
//
// KEY FIXES (v2):
//  12. Re-provisioning: handles ALREADY-CONNECTED WiFi — disconnects old,
//      clears state, saves new creds, reconnects. No reboot needed.
//  13. WiFi SSID retry: on WL_NO_SSID_AVAIL, retries up to 2 more times
//      with 3 second delay before sending FAIL:WIFI_NOTFOUND.
//  14. New error code: FAIL:WIFI_CONNECT_TIMEOUT
//  15. OK response includes device name: "OK:CrashGuard_ESP32"
//  16. Serial logs for every state transition
//  17. Reduced heartbeat interval to 10s for faster status detection
//  18. LED error blink patterns for deployed devices
//  19. WiFi disconnect reason logging
// ============================================================================

#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <WiFi.h>
#include <HTTPClient.h>
#include <Wire.h>
#include <MPU6050.h>
#include <ArduinoJson.h>
#include <Preferences.h>
#include <esp_task_wdt.h>
#include <esp_wifi.h>
#include <time.h>
#include <math.h>

// ─── Configuration ──────────────────────────────────────────────────────────

#define DEVICE_NAME         "CrashGuard_ESP32"
#define SERVICE_UUID        "12345678-1234-1234-1234-1234567890ab"
#define CHARACTERISTIC_UUID "abcd1234-5678-1234-5678-abcdef123456"

#define BUZZER_PIN          25
#define LED_PIN             2     // Built-in LED for status indication
#define MPU_SDA             21
#define MPU_SCL             22
#define WDT_TIMEOUT_SEC     30

// *** IMPORTANT: Must match google-services.json firebase_url ***
// Your RTDB is in asia-southeast1 — using the regional URL.
#define FIREBASE_HOST       "crashguard-c3f65-default-rtdb.asia-southeast1.firebasedatabase.app"

// ─── Accident Detection Thresholds ──────────────────────────────────────────

// Toggle testing mode (low thresholds for breadboard demo)
#define TESTING_MODE

#ifdef TESTING_MODE
  const float    IMPACT_G       = 1.5;
  const float    JERK_THRESHOLD = 5.0;
  const float    GYRO_IGNORE    = 300.0;
  const float    STILL_G        = 1.3;
  const float    STILL_GYRO     = 10.0;
  const uint32_t STILL_TIME     = 3000;
  const uint32_t WINDOW_TIME    = 300;
  const uint32_t COOLDOWN       = 5000;
#else
  const float    IMPACT_G       = 10.0;
  const float    JERK_THRESHOLD = 15.0;
  const float    GYRO_IGNORE    = 900.0;
  const float    STILL_G        = 0.7;
  const float    STILL_GYRO     = 15.0;
  const uint32_t STILL_TIME     = 6000;
  const uint32_t WINDOW_TIME    = 400;
  const uint32_t COOLDOWN       = 10000;
#endif

// ─── Timing Constants ───────────────────────────────────────────────────────

const uint32_t WIFI_TIMEOUT_MS       = 20000;   // 20s max WiFi connect wait per attempt
const uint32_t WIFI_RETRY_MS         = 15000;   // 15s between auto-reconnect attempts
const uint32_t WIFI_SSID_RETRY_DELAY = 3000;    // 3s between SSID-not-found retries
const int      WIFI_SSID_MAX_RETRIES = 3;       // Max attempts before FAIL:WIFI_NOTFOUND
const uint32_t HEARTBEAT_MS          = 10000;   // 10s heartbeat interval
const uint32_t LOOP_DELAY_MS         = 50;      // 50ms loop cycle (20 Hz sampling)

// Non-blocking buzzer config
const uint32_t BUZZER_ON_MS       = 200;     // Buzzer on duration
const uint32_t BUZZER_OFF_MS      = 200;     // Buzzer off duration
const int      BUZZER_CYCLES      = 10;      // Number of beep cycles

// ─── Global State ───────────────────────────────────────────────────────────

// BLE
BLEServer         *pServer = nullptr;
BLECharacteristic *pCharacteristic = nullptr;
bool               bleClientConnected = false;

// WiFi
enum WifiState { WIFI_IDLE, WIFI_CONNECTING, WIFI_CONNECTED, WIFI_FAILED };
WifiState     wifiState       = WIFI_IDLE;
bool          shouldConnectWifi = false;
bool          wifiConnected   = false;
uint32_t      wifiStartTime   = 0;
uint32_t      lastWifiRetry   = 0;
bool          wasOnline       = false;    // Track if we were previously online

// WiFi SSID retry tracking
int           wifiSsidRetryCount  = 0;    // Current retry attempt for SSID-not-found
bool          wifiSsidRetrying    = false; // Whether we're in retry-delay phase
uint32_t      wifiSsidRetryTime   = 0;    // Timestamp of last SSID retry

// Flag: this provisioning attempt was triggered by BLE (vs auto-reconnect)
bool          bleTriggeredProvision = false;

// Credentials (persisted)
Preferences   prefs;
String        wifiSSID     = "";
String        wifiPassword = "";
String        userId       = "";

// NTP
bool          ntpSynced = false;

// MPU6050
MPU6050       mpu;
float         prev_g       = 1.0;
float         baseline_g   = 1.0;
uint32_t      impact_time  = 0;
uint32_t      still_start  = 0;
uint32_t      last_trigger = 0;
bool          monitoring   = false;
int           current_stage = 0;

// Firebase
uint32_t      lastHeartbeat = 0;

// Non-blocking buzzer state
bool          buzzerActive    = false;
uint32_t      buzzerStartTime = 0;
int           buzzerCycleCount = 0;
bool          buzzerIsOn      = false;
uint32_t      buzzerToggleTime = 0;

// LED status blinking (non-blocking)
uint32_t      lastLedToggle   = 0;
bool          ledState        = false;

// ─── Utility ────────────────────────────────────────────────────────────────

float magnitude(float x, float y, float z) {
  return sqrtf(x * x + y * y + z * z);
}

/// Returns real Unix epoch seconds (if NTP synced), else 0.
unsigned long getUnixTime() {
  struct tm timeinfo;
  if (ntpSynced && getLocalTime(&timeinfo, 500)) {
    return mktime(&timeinfo);
  }
  return 0;
}

String getTimestamp() {
  struct tm timeinfo;
  if (ntpSynced && getLocalTime(&timeinfo, 500)) {
    char buf[30];
    strftime(buf, sizeof(buf), "%Y-%m-%dT%H:%M:%SZ", &timeinfo);
    return String(buf);
  }
  // Fallback: millis-based pseudo timestamp
  return String(millis());
}

// ─── LED Status Indicator ───────────────────────────────────────────────────

// Non-blocking LED patterns for visual status feedback:
//   - Solid ON: WiFi connected & operational
//   - Slow blink (1s): BLE advertising, waiting for provisioning
//   - Fast blink (200ms): WiFi connecting
//   - OFF: Error / no credentials

void handleLed() {
  uint32_t now = millis();
  
  if (wifiConnected) {
    // Solid ON when connected
    if (!ledState) {
      digitalWrite(LED_PIN, HIGH);
      ledState = true;
    }
  } else if (wifiState == WIFI_CONNECTING) {
    // Fast blink when connecting to WiFi
    if (now - lastLedToggle >= 200) {
      ledState = !ledState;
      digitalWrite(LED_PIN, ledState ? HIGH : LOW);
      lastLedToggle = now;
    }
  } else if (wifiSSID.length() == 0) {
    // Slow blink when no credentials (waiting for BLE provisioning)
    if (now - lastLedToggle >= 1000) {
      ledState = !ledState;
      digitalWrite(LED_PIN, ledState ? HIGH : LOW);
      lastLedToggle = now;
    }
  } else {
    // OFF on error
    if (ledState) {
      digitalWrite(LED_PIN, LOW);
      ledState = false;
    }
  }
}

// ─── BLE Callbacks ──────────────────────────────────────────────────────────

class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer* s) override {
    bleClientConnected = true;
    Serial.println("[BLE] ✅ App connected");
  }
  void onDisconnect(BLEServer* s) override {
    bleClientConnected = false;
    Serial.println("[BLE] ⚡ App disconnected — restarting advertising");
    // No delay() here — it blocks the GATT callback stack.
    BLEDevice::startAdvertising();
  }
};

class CharCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* c) override {
    // *** CRITICAL: Return IMMEDIATELY — no blocking! ***
    // Parse JSON, save credentials, set flag. WiFi happens in loop().
    std::string raw = c->getValue();
    if (raw.length() == 0) return;

    String value = String(raw.c_str());
    Serial.println("──────────────────────────────────────");
    Serial.print("[BLE] 📥 Received credentials: ");
    Serial.println(value);

    StaticJsonDocument<256> doc;
    DeserializationError err = deserializeJson(doc, value);

    if (err) {
      Serial.printf("[BLE] ❌ JSON parse error: %s\n", err.c_str());
      c->setValue("FAIL:JSON_PARSE");
      c->notify();
      return;
    }

    if (!doc.containsKey("ssid") || !doc.containsKey("pass")) {
      Serial.println("[BLE] ❌ Missing required fields (ssid, pass)");
      c->setValue("FAIL:MISSING_FIELDS");
      c->notify();
      return;
    }

    // ── FIX #1: Handle re-provisioning when WiFi is already connected ──
    if (wifiConnected || wifiState == WIFI_CONNECTED) {
      Serial.println("[BLE] ⚠️  WiFi already connected — disconnecting for re-provisioning...");
      WiFi.disconnect(true);  // true = erase stored config
      delay(100);             // tiny delay for radio to release
      wifiConnected = false;
      wifiState     = WIFI_IDLE;
      wasOnline     = false;
      Serial.println("[BLE] ✅ Old WiFi connection cleared");
    }

    // Also handle if WiFi was in connecting state
    if (wifiState == WIFI_CONNECTING) {
      Serial.println("[BLE] ⚠️  WiFi was connecting — aborting for new credentials...");
      WiFi.disconnect(true);
      delay(100);
      wifiState = WIFI_IDLE;
    }

    wifiSSID     = doc["ssid"].as<String>();
    wifiPassword = doc["pass"].as<String>();
    userId       = doc["uid"] | "";

    // Save to flash so it survives reboot (no EN button needed!)
    prefs.putString("ssid", wifiSSID);
    prefs.putString("pass", wifiPassword);
    prefs.putString("uid",  userId);

    Serial.printf("[BLE] 💾 Saved creds — SSID: %s, UID: %s\n", wifiSSID.c_str(), userId.c_str());

    // ── Reset SSID retry counter for this new provisioning attempt ──
    wifiSsidRetryCount  = 0;
    wifiSsidRetrying    = false;

    // Mark this as a BLE-triggered provision (so we send BLE OK/FAIL responses)
    bleTriggeredProvision = true;

    // Set flag — WiFi connection will happen in loop()
    shouldConnectWifi = true;
    wifiState = WIFI_IDLE;

    Serial.println("[BLE] 🏁 Provisioning started — WiFi will connect in loop()");
    Serial.println("──────────────────────────────────────");
    // Return immediately so ESP32 sends GATT ACK to Android instantly!
  }
};

// ─── WiFi Management (Non-Blocking) ────────────────────────────────────────

void handleWifiConnection() {
  uint32_t now = millis();

  // ── Handle SSID retry delay (non-blocking) ──
  if (wifiSsidRetrying) {
    if (now - wifiSsidRetryTime >= WIFI_SSID_RETRY_DELAY) {
      Serial.printf("[WiFi] 🔄 SSID retry attempt %d/%d...\n", 
                    wifiSsidRetryCount + 1, WIFI_SSID_MAX_RETRIES);
      wifiSsidRetrying  = false;
      wifiState         = WIFI_IDLE;
      shouldConnectWifi = true;
    }
    return; // Don't do anything else during retry delay
  }

  // ── Start connection if flag is set ──
  if (shouldConnectWifi && wifiState == WIFI_IDLE) {
    if (wifiSSID.length() == 0) {
      shouldConnectWifi = false;
      Serial.println("[WiFi] ⚠️  No SSID configured — skipping");
      return;
    }
    Serial.printf("[WiFi] 🔌 Connecting to: \"%s\" (attempt %d/%d)\n", 
                  wifiSSID.c_str(), wifiSsidRetryCount + 1, WIFI_SSID_MAX_RETRIES);
    WiFi.disconnect(true);
    delay(100);
    WiFi.begin(wifiSSID.c_str(), wifiPassword.c_str());
    wifiState     = WIFI_CONNECTING;
    wifiStartTime = millis();
    shouldConnectWifi = false;
  }

  // ── Poll connection status (non-blocking) ──
  if (wifiState == WIFI_CONNECTING) {
    wl_status_t status = WiFi.status();

    if (status == WL_CONNECTED) {
      // ── SUCCESS ──
      wifiState     = WIFI_CONNECTED;
      wifiConnected = true;
      wasOnline     = true;
      Serial.printf("[WiFi] ✅ Connected! IP: %s\n", WiFi.localIP().toString().c_str());

      // Reset retry counter on success
      wifiSsidRetryCount = 0;

      // Send BLE "OK:{DEVICE_NAME}" response so app knows exact device ID
      if (bleTriggeredProvision && bleClientConnected && pCharacteristic != nullptr) {
        String okMsg = String("OK:") + DEVICE_NAME;
        pCharacteristic->setValue(okMsg.c_str());
        pCharacteristic->notify();
        Serial.printf("[BLE] 📤 Sent \"%s\" to app\n", okMsg.c_str());
        bleTriggeredProvision = false;
      }

      // Sync time via NTP (non-blocking, runs in background)
      if (!ntpSynced) {
        configTime(19800, 0, "pool.ntp.org", "time.nist.gov"); // IST offset: +5:30 = 19800s
        ntpSynced = true;
        Serial.println("[NTP] ⏰ Time sync started");
      }

      // Send immediate heartbeat on reconnect
      sendHeartbeat();

    } else if (millis() - wifiStartTime > WIFI_TIMEOUT_MS) {
      // ── TIMEOUT ──
      Serial.printf("[WiFi] ⏰ Connection timeout after %dms (status=%d)\n", 
                    WIFI_TIMEOUT_MS, status);

      // ── FIX #2: Retry on WL_NO_SSID_AVAIL ──
      if (status == WL_NO_SSID_AVAIL && wifiSsidRetryCount < WIFI_SSID_MAX_RETRIES - 1) {
        wifiSsidRetryCount++;
        wifiSsidRetrying  = true;
        wifiSsidRetryTime = millis();
        wifiState         = WIFI_IDLE;
        WiFi.disconnect(true);
        Serial.printf("[WiFi] 🔍 SSID not found — will retry in %dms (attempt %d/%d)\n",
                      WIFI_SSID_RETRY_DELAY, wifiSsidRetryCount + 1, WIFI_SSID_MAX_RETRIES);
        return; // Don't send FAIL yet
      }

      // All retries exhausted — determine specific failure reason
      wifiState     = WIFI_FAILED;
      wifiConnected = false;
      
      String failReason;
      switch (status) {
        case WL_NO_SSID_AVAIL:
          failReason = "FAIL:WIFI_NOTFOUND";
          Serial.println("[WiFi] ❌ SSID not found after all retries — check network name");
          break;
        case WL_CONNECT_FAILED:
          failReason = "FAIL:WIFI_AUTH";
          Serial.println("[WiFi] ❌ Authentication failed — wrong password");
          break;
        case WL_DISCONNECTED:
          failReason = "FAIL:WIFI_CONNECT_TIMEOUT";
          Serial.println("[WiFi] ❌ Connection timeout — router may be out of range");
          break;
        default:
          failReason = "FAIL:WIFI_CONNECT_TIMEOUT";
          Serial.printf("[WiFi] ❌ Connection failed with status=%d\n", status);
          break;
      }

      // Send BLE FAIL response (only if this was a BLE-triggered provisioning)
      if (bleTriggeredProvision && bleClientConnected && pCharacteristic != nullptr) {
        pCharacteristic->setValue(failReason.c_str());
        pCharacteristic->notify();
        Serial.printf("[BLE] 📤 Sent \"%s\" to app\n", failReason.c_str());
        bleTriggeredProvision = false;
      }

      // Reset retry counter after final failure
      wifiSsidRetryCount = 0;
    }
  }

  // ── Auto-reconnect if WiFi drops (not BLE-triggered) ──
  if (wifiState == WIFI_CONNECTED && WiFi.status() != WL_CONNECTED) {
    Serial.println("[WiFi] ⚡ Connection lost — writing offline status & reconnecting...");
    
    // Write offline status to Firebase BEFORE losing connection fully
    if (wasOnline) {
      writeOfflineStatus();
      wasOnline = false;
    }
    
    wifiConnected = false;
    wifiState     = WIFI_IDLE;
    shouldConnectWifi = true;
    bleTriggeredProvision = false; // Auto-reconnect, not BLE
    wifiSsidRetryCount   = 0;     // Reset retry counter
  }

  // ── Retry after failure (auto-reconnect only, not BLE provision) ──
  if (wifiState == WIFI_FAILED && wifiSSID.length() > 0 && !bleTriggeredProvision) {
    if (millis() - wifiStartTime > WIFI_RETRY_MS) {
      Serial.println("[WiFi] 🔄 Auto-reconnect retry...");
      wifiState = WIFI_IDLE;
      shouldConnectWifi     = true;
      wifiSsidRetryCount    = 0;
    }
  }
}

// ─── Firebase REST API ──────────────────────────────────────────────────────

void firebasePost(const char* path, const String& json) {
  if (!wifiConnected) return;

  HTTPClient http;
  String url = String("https://") + FIREBASE_HOST + "/" + path + ".json";
  http.begin(url);
  http.addHeader("Content-Type", "application/json");
  http.setTimeout(5000);

  esp_task_wdt_reset(); // Feed watchdog before potentially slow HTTP call
  int code = http.POST(json);
  esp_task_wdt_reset(); // Feed watchdog after HTTP call completes

  if (code > 0) {
    Serial.printf("[Firebase] POST %s → %d\n", path, code);
  } else {
    Serial.printf("[Firebase] POST failed: %s\n", http.errorToString(code).c_str());
  }
  http.end();
}

void firebasePatch(const char* path, const String& json) {
  if (!wifiConnected) return;

  HTTPClient http;
  String url = String("https://") + FIREBASE_HOST + "/" + path + ".json";
  http.begin(url);
  http.addHeader("Content-Type", "application/json");
  http.setTimeout(5000);

  esp_task_wdt_reset(); // Feed watchdog before potentially slow HTTP call
  int code = http.sendRequest("PATCH", json);
  esp_task_wdt_reset(); // Feed watchdog after HTTP call completes

  if (code > 0) {
    Serial.printf("[Firebase] PATCH %s → %d\n", path, code);
  } else {
    Serial.printf("[Firebase] PATCH failed: %s\n", http.errorToString(code).c_str());
  }
  http.end();
}

void reportAccidentToFirebase() {
  String ts = getTimestamp();

  // POST to accidents/{DEVICE_NAME} — Firebase auto-generates push key
  String path = String("accidents/") + DEVICE_NAME;
  String json = "{";
  json += "\"status\":\"ACCIDENT\",";
  json += "\"device_id\":\"" + String(DEVICE_NAME) + "\",";
  json += "\"timestamp\":\"" + ts + "\",";
  json += "\"latitude\":0,";
  json += "\"longitude\":0";
  json += "}";

  firebasePost(path.c_str(), json);
}

void sendHeartbeat() {
  // Use real Unix epoch timestamp instead of millis()
  unsigned long unixTime = getUnixTime();
  String lastSeenValue;
  if (unixTime > 0) {
    // Real Unix epoch milliseconds (what Firebase/Flutter expects)
    lastSeenValue = String((unsigned long long)unixTime * 1000ULL);
  } else {
    // Fallback: current millis + a large offset to signal it's uptime-based
    lastSeenValue = String(millis());
  }

  String path = String("devices/") + DEVICE_NAME;
  String json = "{\"status\":\"online\",\"lastSeen\":" + lastSeenValue + "}";
  firebasePatch(path.c_str(), json);
  Serial.printf("[Heartbeat] 💓 Sent (lastSeen: %s)\n", lastSeenValue.c_str());
}

/// Writes offline status to Firebase when WiFi is about to drop.
void writeOfflineStatus() {
  // Try to write offline status — may fail if WiFi is already gone,
  // but worth attempting. The app's staleness detection will catch it too.
  String path = String("devices/") + DEVICE_NAME;
  String json = "{\"status\":\"offline\"}";
  
  HTTPClient http;
  String url = String("https://") + FIREBASE_HOST + "/" + path + ".json";
  http.begin(url);
  http.addHeader("Content-Type", "application/json");
  http.setTimeout(2000); // Short timeout since WiFi is already flaky
  
  int code = http.sendRequest("PATCH", json);
  if (code > 0) {
    Serial.printf("[Firebase] Wrote offline status → %d\n", code);
  } else {
    Serial.println("[Firebase] Offline write failed (WiFi already gone)");
  }
  http.end();
}

// ─── Non-Blocking Buzzer ────────────────────────────────────────────────────

/// Starts the non-blocking buzzer alarm sequence.
void startBuzzer() {
  buzzerActive     = true;
  buzzerCycleCount = 0;
  buzzerIsOn       = true;
  buzzerToggleTime = millis();
  digitalWrite(BUZZER_PIN, HIGH);
  Serial.println("[Buzzer] 🔔 Alarm started (non-blocking)");
}

/// Must be called every loop iteration to drive the buzzer.
void handleBuzzer() {
  if (!buzzerActive) return;
  
  uint32_t now = millis();
  
  if (buzzerIsOn) {
    // Buzzer is currently ON — check if it's time to turn OFF
    if (now - buzzerToggleTime >= BUZZER_ON_MS) {
      digitalWrite(BUZZER_PIN, LOW);
      buzzerIsOn = false;
      buzzerToggleTime = now;
      buzzerCycleCount++;
      
      if (buzzerCycleCount >= BUZZER_CYCLES) {
        // All cycles done
        buzzerActive = false;
        Serial.println("[Buzzer] ✅ Alarm finished");
      }
    }
  } else {
    // Buzzer is currently OFF — check if it's time to turn ON
    if (now - buzzerToggleTime >= BUZZER_OFF_MS) {
      digitalWrite(BUZZER_PIN, HIGH);
      buzzerIsOn = true;
      buzzerToggleTime = now;
    }
  }
}

// ─── Accident Detection ─────────────────────────────────────────────────────

void resetAccidentState() {
  monitoring    = false;
  still_start   = 0;
  impact_time   = 0;
  current_stage = 0;
}

void triggerAlarm() {
  Serial.println("\n================================================");
  Serial.println("          *** ACCIDENT DETECTED ***");
  Serial.println("================================================");

  // 1. Report to Firebase (app will handle SMS via Twilio)
  //    This is a blocking HTTP call but has watchdog protection now.
  reportAccidentToFirebase();

  // 2. Start NON-BLOCKING buzzer alert (WiFi stays alive!)
  startBuzzer();

  last_trigger = millis();
}

void processAccidentDetection() {
  int16_t ax, ay, az, gx, gy, gz;
  mpu.getMotion6(&ax, &ay, &az, &gx, &gy, &gz);

  float ax_g = ax / 16384.0f;
  float ay_g = ay / 16384.0f;
  float az_g = az / 16384.0f;
  float gx_d = gx / 131.0f;
  float gy_d = gy / 131.0f;
  float gz_d = gz / 131.0f;

  float total_g    = magnitude(ax_g, ay_g, az_g);
  float total_gyro = magnitude(gx_d, gy_d, gz_d);

  // Update baseline when not monitoring
  if (!monitoring) {
    baseline_g = 0.95f * baseline_g + 0.05f * total_g;
  }

  float jerk = fabsf(total_g - prev_g) / (LOOP_DELAY_MS / 1000.0f);
  prev_g = total_g;

  // ── STAGE 1: Impact Detection ──
  if (!monitoring && (millis() - last_trigger > COOLDOWN)) {
    float g_spike = total_g - baseline_g;
    if (g_spike > IMPACT_G && jerk > JERK_THRESHOLD) {
      if (total_gyro < GYRO_IGNORE) {
        monitoring    = true;
        impact_time   = millis();
        still_start   = 0;
        current_stage = 1;
        Serial.println("\n>> STAGE 1: Impact detected!");
        Serial.printf("   Spike: %.2fg | Jerk: %.1f\n", g_spike, jerk);
      }
    }
  }

  // ── STAGE 2: Confirmation Window ──
  if (monitoring && current_stage == 1) {
    uint32_t elapsed = millis() - impact_time;
    if (elapsed > WINDOW_TIME) {
      Serial.println(">> STAGE 2 FAILED: No confirmation — likely false trigger");
      resetAccidentState();
    } else {
      current_stage = 2;
    }
  }

  // ── STAGE 3: Stillness Detection ──
  if (monitoring && current_stage >= 2) {
    if (total_g < STILL_G && total_gyro < STILL_GYRO) {
      if (still_start == 0) {
        still_start   = millis();
        current_stage = 3;
        Serial.println(">> STAGE 3: Stillness detected — timing...");
      }

      uint32_t still_duration = millis() - still_start;
      if (still_duration >= STILL_TIME) {
        triggerAlarm();
        resetAccidentState();
      }
    } else {
      if (still_start != 0) {
        Serial.println(">> STAGE 3 RESET: Movement detected");
        still_start = 0;
      }
      // Timeout: rider is moving — probably OK
      if (millis() - impact_time > 15000) {
        Serial.println(">> Timeout: No prolonged stillness — rider OK");
        resetAccidentState();
      }
    }
  }
}

// ─── Setup ──────────────────────────────────────────────────────────────────

void setup() {
  Serial.begin(115200);
  Serial.println("\n[CrashGuard] 🚀 Booting...");

  // Hardware watchdog — auto-resets if hung (NO EN BUTTON NEEDED!)
  esp_task_wdt_init(WDT_TIMEOUT_SEC, true);
  esp_task_wdt_add(NULL);

  // Buzzer
  pinMode(BUZZER_PIN, OUTPUT);
  digitalWrite(BUZZER_PIN, LOW);

  // LED status indicator
  pinMode(LED_PIN, OUTPUT);
  digitalWrite(LED_PIN, LOW);

  // MPU6050
  Wire.begin(MPU_SDA, MPU_SCL);
  mpu.initialize();
  if (mpu.testConnection()) {
    Serial.println("[MPU6050] ✅ Connected OK");
  } else {
    Serial.println("[MPU6050] ❌ Connection FAILED — check wiring");
  }

  // Calibrate baseline (3 seconds)
  Serial.println("[MPU6050] 📊 Calibrating baseline...");
  for (int i = 0; i < 30; i++) {
    int16_t ax, ay, az, gx, gy, gz;
    mpu.getMotion6(&ax, &ay, &az, &gx, &gy, &gz);
    float g = magnitude(ax / 16384.0f, ay / 16384.0f, az / 16384.0f);
    baseline_g = 0.95f * baseline_g + 0.05f * g;
    delay(100);
    esp_task_wdt_reset();
  }
  Serial.printf("[MPU6050] ✅ Baseline: %.2fg\n", baseline_g);

  // Load saved credentials from flash
  prefs.begin("crashguard", false);
  wifiSSID     = prefs.getString("ssid", "");
  wifiPassword = prefs.getString("pass", "");
  userId       = prefs.getString("uid",  "");

  if (wifiSSID.length() > 0) {
    Serial.printf("[Boot] 📡 Found saved WiFi: \"%s\" — auto-connecting\n", wifiSSID.c_str());
    shouldConnectWifi     = true;
    bleTriggeredProvision = false; // Auto-reconnect, not BLE
  } else {
    Serial.println("[Boot] 📱 No saved credentials — waiting for BLE provisioning");
  }

  // BLE Setup
  BLEDevice::init(DEVICE_NAME);
  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new ServerCallbacks());

  BLEService *pService = pServer->createService(SERVICE_UUID);

  pCharacteristic = pService->createCharacteristic(
    CHARACTERISTIC_UUID,
    BLECharacteristic::PROPERTY_READ   |
    BLECharacteristic::PROPERTY_WRITE  |
    BLECharacteristic::PROPERTY_NOTIFY |
    BLECharacteristic::PROPERTY_WRITE_NR
  );
  pCharacteristic->setCallbacks(new CharCallbacks());
  pCharacteristic->addDescriptor(new BLE2902());

  pService->start();

  BLEAdvertising *pAdvertising = BLEDevice::getAdvertising();
  pAdvertising->addServiceUUID(SERVICE_UUID);
  pAdvertising->setScanResponse(true);
  pAdvertising->setMinPreferred(0x06);
  pAdvertising->setMinPreferred(0x12);
  pAdvertising->start();

  Serial.println("========================================");
  #ifdef TESTING_MODE
    Serial.println("  MODE: TESTING (breadboard)");
  #else
    Serial.println("  MODE: HELMET DEPLOYMENT");
  #endif
  Serial.printf("  Device ID: %s\n", DEVICE_NAME);
  Serial.println("  CrashGuard ESP32 Ready");
  Serial.println("  BLE advertising as: " DEVICE_NAME);
  Serial.println("========================================\n");
}

// ─── Main Loop ──────────────────────────────────────────────────────────────

void loop() {
  // Feed the watchdog (prevents EN button resets!)
  esp_task_wdt_reset();

  // 1. Handle WiFi (non-blocking)
  handleWifiConnection();

  // 2. Drive non-blocking buzzer
  handleBuzzer();

  // 3. Update LED status indicator
  handleLed();

  // 4. Send heartbeat to Firebase every 10s
  if (wifiConnected && (millis() - lastHeartbeat > HEARTBEAT_MS)) {
    sendHeartbeat();
    lastHeartbeat = millis();
  }

  // 5. Run accident detection pipeline
  processAccidentDetection();

  // Small delay — 20 Hz is plenty for MPU6050 accident detection
  delay(LOOP_DELAY_MS);
}
