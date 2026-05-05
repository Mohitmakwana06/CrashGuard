// ============================================================================
// CrashGuard ESP32 — Production Firmware
// ============================================================================
// BLE is always ON at boot and visible immediately.
// BLE window (30s) only auto-closes if NO client connects.
// If a client connects, BLE stays until creds are received + client disconnects.
// WiFi starts only AFTER BLE is fully stopped and radio released.
// Saved credentials → WiFi connects automatically after BLE window.
// ============================================================================

#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <WiFi.h>
#include <HTTPClient.h>
#include <WiFiClientSecure.h>
#include <Wire.h>
#include <MPU6050.h>
#include <ArduinoJson.h>
#include <Preferences.h>
#include <time.h>
#include <math.h>

// ─── Debug ──────────────────────────────────────────────────────────────────
// 0 = silent | 1 = info (default) | 2 = verbose
#define DEBUG_LEVEL 1

#define LOG_INFO(fmt, ...)  if (DEBUG_LEVEL >= 1) Serial.printf("[INFO]  " fmt "\n", ##__VA_ARGS__)
#define LOG_WARN(fmt, ...)  if (DEBUG_LEVEL >= 1) Serial.printf("[WARN]  " fmt "\n", ##__VA_ARGS__)
#define LOG_ERROR(fmt, ...) Serial.printf("[ERROR] " fmt "\n", ##__VA_ARGS__)
#define LOG_DEBUG(fmt, ...) if (DEBUG_LEVEL >= 2) Serial.printf("[DEBUG] " fmt "\n", ##__VA_ARGS__)

// ─── Pin / Device Config ────────────────────────────────────────────────────
#define DEVICE_NAME         "CrashGuard_ESP32"
#define SERVICE_UUID        "12345678-1234-1234-1234-1234567890ab"
#define CHARACTERISTIC_UUID "abcd1234-5678-1234-5678-abcdef123456"
#define BUZZER_PIN          25
#define MOTOR_PIN           23
#define LED_PIN             2
#define MPU_SDA             21
#define MPU_SCL             22
#define FIREBASE_HOST       "crashguard-c3f65-default-rtdb.asia-southeast1.firebasedatabase.app"

// ─── Timing ─────────────────────────────────────────────────────────────────
const uint32_t BLE_WINDOW_MS         = 30000;  // Auto-close BLE if no client connects
const uint32_t BLE_RADIO_RELEASE_MS  = 300;    // Delay after BLE deinit before WiFi
const uint32_t WIFI_TIMEOUT_MS       = 20000;
const uint32_t WIFI_RETRY_MS         = 15000;
const uint32_t WIFI_SSID_RETRY_DELAY = 3000;
const int      WIFI_SSID_MAX_RETRIES = 3;
const uint32_t NTP_SYNC_TIMEOUT_MS   = 10000;
const uint32_t HEARTBEAT_MS          = 10000;
const uint32_t LOOP_DELAY_MS         = 50;
const uint32_t ALARM_DURATION_MS     = 15000;  // Must be < COOLDOWN

// ─── Detection Thresholds (Testing) ─────────────────────────────────────────
const float    IMPACT_G       = 1.5;
const float    JERK_THRESHOLD = 3.0;
const float    GYRO_IGNORE    = 300.0;
const float    STILL_G        = 1.3;
const float    STILL_GYRO     = 10.0;
const uint32_t STILL_TIME     = 2000;
const uint32_t WINDOW_TIME    = 300;
const uint32_t COOLDOWN       = 20000;  // Must be > ALARM_DURATION_MS ✓

// ─── Detection Thresholds (Deployment — uncomment for helmet) ───────────────
// const float    IMPACT_G       = 10.0;
// const float    JERK_THRESHOLD = 15.0;
// const float    GYRO_IGNORE    = 900.0;
// const float    STILL_G        = 0.7;
// const float    STILL_GYRO     = 15.0;
// const uint32_t STILL_TIME     = 6000;
// const uint32_t WINDOW_TIME    = 400;
// const uint32_t COOLDOWN       = 20000;

// ─── Forward Declarations ───────────────────────────────────────────────────
void startBLE();
void stopBLE();
void startWifi();
void sendHeartbeat();
void writeOfflineStatus();
void reportAccidentToFirebase();

// ─── BLE State ──────────────────────────────────────────────────────────────
BLEServer*         pServer         = nullptr;
BLECharacteristic* pCharacteristic = nullptr;
bool bleRunning          = false;
bool bleClientConnected  = false;
bool bleCredsReceived    = false;  // Set in onWrite, consumed in handleBleLifecycle
bool bleProvisionPending = false;  // True if WiFi connect was triggered via BLE

// ─── WiFi State ─────────────────────────────────────────────────────────────
enum WifiState { WIFI_IDLE, WIFI_CONNECTING, WIFI_CONNECTED, WIFI_FAILED };
WifiState wifiState         = WIFI_IDLE;
bool      wifiConnected     = false;
bool      shouldConnectWifi = false;
uint32_t  wifiStartTime     = 0;
bool      wasOnline         = false;
int       ssidRetryCount    = 0;
bool      ssidRetrying      = false;
uint32_t  ssidRetryTime     = 0;
int       totalWifiFails    = 0;

// ─── Credentials ────────────────────────────────────────────────────────────
Preferences prefs;
String wifiSSID     = "";
String wifiPassword = "";
String userId       = "";

// ─── NTP ────────────────────────────────────────────────────────────────────
bool     ntpSynced    = false;
bool     ntpWaiting   = false;
uint32_t ntpStartTime = 0;

// ─── Heartbeat ──────────────────────────────────────────────────────────────
bool     firstHeartbeatSent = false;
uint32_t lastHeartbeat      = 0;

// ─── MPU6050 / Detection ────────────────────────────────────────────────────
MPU6050  mpu;
float    prev_g       = 1.0;
float    baseline_g   = 1.0;
uint32_t impact_time  = 0;
uint32_t still_start  = 0;
uint32_t last_trigger = 0;
bool     monitoring   = false;
int      stage        = 0;

// ─── Alarm ──────────────────────────────────────────────────────────────────
bool     alarmActive    = false;
uint32_t alarmStartTime = 0;

// ─── LED ────────────────────────────────────────────────────────────────────
uint32_t lastLedToggle = 0;
bool     ledState      = false;

// ─── Utility ────────────────────────────────────────────────────────────────

float magnitude(float x, float y, float z) {
  return sqrtf(x * x + y * y + z * z);
}

unsigned long getUnixTime() {
  struct tm t;
  return (ntpSynced && getLocalTime(&t, 500)) ? (unsigned long)mktime(&t) : 0;
}

String getTimestamp() {
  struct tm t;
  if (ntpSynced && getLocalTime(&t, 500)) {
    char buf[30];
    strftime(buf, sizeof(buf), "%Y-%m-%dT%H:%M:%SZ", &t);
    return String(buf);
  }
  return String(millis());
}

const char* wifiStatusStr(wl_status_t s) {
  switch (s) {
    case WL_CONNECTED:       return "WL_CONNECTED";
    case WL_NO_SSID_AVAIL:   return "WL_NO_SSID_AVAIL";
    case WL_CONNECT_FAILED:  return "WL_CONNECT_FAILED";
    case WL_CONNECTION_LOST: return "WL_CONNECTION_LOST";
    case WL_DISCONNECTED:    return "WL_DISCONNECTED";
    case WL_IDLE_STATUS:     return "WL_IDLE_STATUS";
    default:                 return "WL_UNKNOWN";
  }
}

// ─── Alarm ──────────────────────────────────────────────────────────────────

void startAlarm() {
  alarmActive    = true;
  alarmStartTime = millis();
  digitalWrite(BUZZER_PIN, HIGH);
  digitalWrite(MOTOR_PIN,  HIGH);
  LOG_INFO("[Alarm] STARTED — buzzer + motor ON for %lus", ALARM_DURATION_MS / 1000);
}

void stopAlarm() {
  alarmActive = false;
  digitalWrite(BUZZER_PIN, LOW);
  digitalWrite(MOTOR_PIN,  LOW);
  LOG_INFO("[Alarm] STOPPED");
}

void handleAlarm() {
  if (!alarmActive) return;
  if (millis() - alarmStartTime >= ALARM_DURATION_MS) {
    LOG_INFO("[Alarm] Duration reached — stopping");
    stopAlarm();
  }
}

// ─── LED ────────────────────────────────────────────────────────────────────

void handleLed() {
  uint32_t now = millis();
  if (wifiConnected) {
    // Solid ON
    if (!ledState) { digitalWrite(LED_PIN, HIGH); ledState = true; }
  } else if (wifiState == WIFI_CONNECTING) {
    // Fast blink — connecting
    if (now - lastLedToggle >= 200) {
      ledState = !ledState;
      digitalWrite(LED_PIN, ledState ? HIGH : LOW);
      lastLedToggle = now;
    }
  } else if (wifiSSID.length() == 0) {
    // Slow blink — no credentials, waiting for provisioning
    if (now - lastLedToggle >= 1000) {
      ledState = !ledState;
      digitalWrite(LED_PIN, ledState ? HIGH : LOW);
      lastLedToggle = now;
    }
  } else {
    // OFF — idle/failed
    if (ledState) { digitalWrite(LED_PIN, LOW); ledState = false; }
  }
}

// ─── NTP ────────────────────────────────────────────────────────────────────

void startNtp() {
  configTime(19800, 0, "pool.ntp.org", "time.nist.gov");
  ntpStartTime = millis();
  ntpWaiting   = true;
  LOG_INFO("[NTP] Sync started (UTC+5:30 IST)");
}

void handleNtpSync() {
  if (!ntpWaiting || ntpSynced) return;
  struct tm t;
  uint32_t elapsed = millis() - ntpStartTime;
  if (getLocalTime(&t, 100)) {
    ntpSynced  = true;
    ntpWaiting = false;
    LOG_INFO("[NTP] Synced in %lums — %02d:%02d:%02d UTC+5:30", elapsed, t.tm_hour, t.tm_min, t.tm_sec);
  } else if (elapsed > NTP_SYNC_TIMEOUT_MS) {
    ntpWaiting = false;
    LOG_WARN("[NTP] Timed out — using millis() fallback");
  } else {
    return; // Still waiting
  }
  // Send first heartbeat after NTP resolves (either synced or timed out)
  if (!firstHeartbeatSent) {
    sendHeartbeat();
    lastHeartbeat      = millis();
    firstHeartbeatSent = true;
  }
}

// ─── BLE ────────────────────────────────────────────────────────────────────

class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer*) override {
    bleClientConnected = true;
    LOG_INFO("[BLE] Client connected");
  }
  void onDisconnect(BLEServer*) override {
    bleClientConnected = false;
    LOG_INFO("[BLE] Client disconnected");
    // Restart advertising only if we're still in BLE mode (no creds received yet)
    if (bleRunning && !bleCredsReceived) {
      BLEDevice::startAdvertising();
      LOG_DEBUG("[BLE] Advertising restarted");
    }
  }
};

class CharCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* c) override {
    String raw = c->getValue();
    if (raw.length() == 0) {
      LOG_WARN("[BLE] Empty payload — ignoring");
      return;
    }

    StaticJsonDocument<256> doc;
    if (deserializeJson(doc, raw) != DeserializationError::Ok ||
        !doc.containsKey("ssid") || !doc.containsKey("pass")) {
      LOG_ERROR("[BLE] Invalid JSON payload");
      c->setValue("FAIL:INVALID");
      c->notify();
      return;
    }

    String ssid = doc["ssid"].as<String>();
    String pass = doc["pass"].as<String>();
    String uid  = doc["uid"] | "";
    ssid.trim(); pass.trim();

    if (ssid.length() == 0) {
      LOG_ERROR("[BLE] SSID empty — rejecting");
      c->setValue("FAIL:INVALID");
      c->notify();
      return;
    }

    wifiSSID     = ssid;
    wifiPassword = pass;
    userId       = uid;

    prefs.putString("ssid", wifiSSID);
    prefs.putString("pass", wifiPassword);
    prefs.putString("uid",  userId);

    LOG_INFO("[BLE] Credentials saved — SSID: [%s]  UID: [%s]",
             wifiSSID.c_str(), userId.length() > 0 ? userId.c_str() : "(none)");

    // Flag received — WiFi starts only after BLE is stopped and radio released
    bleCredsReceived    = true;
    bleProvisionPending = true;
    LOG_INFO("[BLE] Credentials received — will stop BLE and connect WiFi");
  }
};

void stopBLE() {
  if (!bleRunning) return;
  LOG_INFO("[BLE] Stopping — releasing radio...");
  BLEDevice::getAdvertising()->stop();
  BLEDevice::deinit(true);
  bleRunning         = false;
  bleClientConnected = false;
  pServer            = nullptr;
  pCharacteristic    = nullptr;
  delay(BLE_RADIO_RELEASE_MS);
  LOG_INFO("[BLE] Stopped. Free heap: %d bytes", ESP.getFreeHeap());
}

void startBLE() {
  if (bleRunning) return;
  LOG_INFO("[BLE] Starting — advertising as [%s]", DEVICE_NAME);
  BLEDevice::init(DEVICE_NAME);
  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new ServerCallbacks());

  BLEService* svc = pServer->createService(SERVICE_UUID);
  pCharacteristic = svc->createCharacteristic(
    CHARACTERISTIC_UUID,
    BLECharacteristic::PROPERTY_READ   |
    BLECharacteristic::PROPERTY_WRITE  |
    BLECharacteristic::PROPERTY_NOTIFY |
    BLECharacteristic::PROPERTY_WRITE_NR
  );
  pCharacteristic->setCallbacks(new CharCallbacks());
  pCharacteristic->addDescriptor(new BLE2902());
  svc->start();

  BLEAdvertising* adv = BLEDevice::getAdvertising();
  adv->addServiceUUID(SERVICE_UUID);
  adv->setScanResponse(true);
  adv->setMinPreferred(0x06);
  adv->setMaxPreferred(0x12);
  adv->start();

  bleRunning = true;
  LOG_INFO("[BLE] Advertising started — window: %lus", BLE_WINDOW_MS / 1000);
}

// Controls entire BLE lifecycle:
// - Auto-closes after BLE_WINDOW_MS if no client ever connects
// - Keeps open while client is connected
// - Closes after creds received AND client disconnects
// - Then triggers WiFi
void handleBleLifecycle() {
  if (!bleRunning) return;

  uint32_t now = millis();

  // If creds received, wait for client to disconnect (so notification can be sent)
  if (bleCredsReceived) {
    if (bleClientConnected) {
      LOG_DEBUG("[BLE] Waiting for client to disconnect before stopping...");
      return;
    }
    // Client gone — safe to stop
    LOG_INFO("[BLE] Creds received + client gone — stopping BLE");
    stopBLE();
    bleCredsReceived = false;
    if (wifiSSID.length() > 0) {
      shouldConnectWifi = true;
      LOG_INFO("[BLE→WiFi] Triggering WiFi connect to [%s]", wifiSSID.c_str());
    }
    return;
  }

  // No creds — close BLE window if expired AND no active connection
  if (now >= BLE_WINDOW_MS && !bleClientConnected) {
    LOG_INFO("[BLE] Window expired (%lums) — no client connected, stopping BLE", now);
    stopBLE();
    if (wifiSSID.length() > 0) {
      shouldConnectWifi = true;
      LOG_INFO("[BLE→WiFi] Triggering WiFi connect to saved SSID [%s]", wifiSSID.c_str());
    } else {
      LOG_WARN("[BLE] No saved SSID — device idle until re-provisioned");
    }
    return;
  }

  // If a client is connected, extend window (keep BLE alive while talking)
  if (bleClientConnected && now >= BLE_WINDOW_MS) {
    LOG_DEBUG("[BLE] Window expired but client still connected — keeping BLE alive");
  }
}

// ─── WiFi ───────────────────────────────────────────────────────────────────

void startWifi() {
  if (wifiSSID.length() == 0) {
    LOG_WARN("[WiFi] startWifi() called with empty SSID — aborting");
    return;
  }
  LOG_INFO("[WiFi] Connecting to [%s] (pass len: %d)", wifiSSID.c_str(), wifiPassword.length());
  WiFi.disconnect(true);
  delay(100);
  WiFi.begin(wifiSSID.c_str(), wifiPassword.c_str());
  wifiState         = WIFI_CONNECTING;
  wifiStartTime     = millis();
  shouldConnectWifi = false;
}

void handleWifiConnection() {
  uint32_t now = millis();

  // Trigger connection when flagged
  if (shouldConnectWifi && wifiState == WIFI_IDLE && !bleRunning) {
    startWifi();
    return;
  }

  // SSID retry delay
  if (ssidRetrying) {
    if (now - ssidRetryTime < WIFI_SSID_RETRY_DELAY) return;
    LOG_INFO("[WiFi] Retrying SSID (attempt %d/%d)", ssidRetryCount + 1, WIFI_SSID_MAX_RETRIES);
    ssidRetrying      = false;
    wifiState         = WIFI_IDLE;
    shouldConnectWifi = true;
    return;
  }

  // Monitor active connection attempt
  if (wifiState == WIFI_CONNECTING) {
    wl_status_t s    = WiFi.status();
    uint32_t elapsed = now - wifiStartTime;

    if (s == WL_CONNECTED) {
      wifiState          = WIFI_CONNECTED;
      wifiConnected      = true;
      wasOnline          = true;
      firstHeartbeatSent = false;
      ssidRetryCount     = 0;
      totalWifiFails     = 0;
      LOG_INFO("[WiFi] Connected to [%s] in %lums — IP: %s  RSSI: %d dBm",
               wifiSSID.c_str(), elapsed,
               WiFi.localIP().toString().c_str(), WiFi.RSSI());

      // Notify BLE app of success (only if BLE is somehow still running — edge case)
      if (bleProvisionPending && bleClientConnected && pCharacteristic) {
        String ok = String("OK:") + DEVICE_NAME;
        pCharacteristic->setValue(ok.c_str());
        pCharacteristic->notify();
        LOG_INFO("[BLE] Sent OK to client: [%s]", ok.c_str());
        delay(200);
      }
      bleProvisionPending = false;

      // Start NTP now that WiFi is up
      if (!ntpSynced) startNtp();
      else {
        sendHeartbeat();
        lastHeartbeat      = millis();
        firstHeartbeatSent = true;
      }
      return;
    }

    if (elapsed > WIFI_TIMEOUT_MS) {
      LOG_WARN("[WiFi] Timeout after %lums — status: %s", elapsed, wifiStatusStr(s));

      if (s == WL_NO_SSID_AVAIL) {
        if (ssidRetryCount < WIFI_SSID_MAX_RETRIES - 1) {
          ssidRetryCount++;
          ssidRetrying  = true;
          ssidRetryTime = millis();
          wifiState     = WIFI_IDLE;
          WiFi.disconnect(true);
          LOG_INFO("[WiFi] SSID not found — retry %d/%d in %lums",
                   ssidRetryCount, WIFI_SSID_MAX_RETRIES, WIFI_SSID_RETRY_DELAY);
          return;
        }
        LOG_ERROR("[WiFi] SSID [%s] not found after %d attempts", wifiSSID.c_str(), WIFI_SSID_MAX_RETRIES);
      } else if (s == WL_CONNECT_FAILED) {
        LOG_ERROR("[WiFi] Wrong password for [%s]", wifiSSID.c_str());
      } else {
        LOG_ERROR("[WiFi] Failed — %s", wifiStatusStr(s));
      }

      // Notify BLE app of failure
      if (bleProvisionPending && bleClientConnected && pCharacteristic) {
        const char* reason = (s == WL_NO_SSID_AVAIL)  ? "FAIL:WIFI_NOTFOUND" :
                             (s == WL_CONNECT_FAILED)  ? "FAIL:WIFI_AUTH"     :
                                                         "FAIL:WIFI_TIMEOUT";
        pCharacteristic->setValue(reason);
        pCharacteristic->notify();
        LOG_INFO("[BLE] Sent failure: [%s]", reason);
      }
      bleProvisionPending = false;

      wifiState      = WIFI_FAILED;
      wifiConnected  = false;
      ssidRetryCount = 0;
      totalWifiFails++;
      LOG_WARN("[WiFi] Total failures: %d", totalWifiFails);

      // After 3 failures, restart BLE so user can re-provision
      if (totalWifiFails >= 3) {
        LOG_WARN("[WiFi] 3 failures — restarting BLE for re-provisioning");
        totalWifiFails = 0;
        startBLE();
      }
      return;
    }

    // Still connecting — periodic log
    static uint32_t lastConnLog = 0;
    if (now - lastConnLog >= 2000) {
      LOG_INFO("[WiFi] Connecting... %lums elapsed  status: %s", elapsed, wifiStatusStr(s));
      lastConnLog = now;
    }
    return;
  }

  // Detect unexpected drop from CONNECTED state
  if (wifiState == WIFI_CONNECTED && WiFi.status() != WL_CONNECTED) {
    LOG_WARN("[WiFi] Connection lost — scheduling reconnect");
    if (wasOnline) { writeOfflineStatus(); wasOnline = false; }
    wifiConnected      = false;
    wifiState          = WIFI_IDLE;
    shouldConnectWifi  = true;
    firstHeartbeatSent = false;
    ntpWaiting         = false;
    ssidRetryCount     = 0;
    return;
  }

  // Auto-retry after WIFI_RETRY_MS in FAILED state
  if (wifiState == WIFI_FAILED && wifiSSID.length() > 0 && !bleRunning) {
    if (now - wifiStartTime > WIFI_RETRY_MS) {
      LOG_INFO("[WiFi] Auto-retry after %lums in FAILED state", now - wifiStartTime);
      wifiState         = WIFI_IDLE;
      shouldConnectWifi = true;
      ssidRetryCount    = 0;
    }
  }
}

// ─── Firebase ───────────────────────────────────────────────────────────────

bool firebaseRequest(const char* method, const char* path, const String& body) {
  if (WiFi.status() != WL_CONNECTED) {
    LOG_WARN("[Firebase] Skipping — WiFi not connected");
    return false;
  }
  WiFiClientSecure client;
  client.setInsecure();
  HTTPClient http;
  String url = String("https://") + FIREBASE_HOST + "/" + path + ".json";
  if (!http.begin(client, url)) {
    LOG_ERROR("[Firebase] http.begin() failed: %s", url.c_str());
    return false;
  }
  http.addHeader("Content-Type", "application/json");
  http.setTimeout(15000);
  uint32_t t0   = millis();
  int      code = (strcmp(method, "POST") == 0) ? http.POST(body) : http.sendRequest(method, body);
  uint32_t rtt  = millis() - t0;
  http.end();
  if (code >= 200 && code < 300) {
    LOG_INFO("[Firebase] %s %s → HTTP %d  RTT=%lums", method, path, code, rtt);
    return true;
  }
  LOG_ERROR("[Firebase] %s %s → HTTP %d  RTT=%lums", method, path, code, rtt);
  return false;
}

void sendHeartbeat() {
  unsigned long t = getUnixTime();
  String ts   = (t > 0) ? String((unsigned long long)t * 1000ULL) : String(millis());
  String path = String("devices/") + DEVICE_NAME;
  String json = "{\"status\":\"online\",\"lastSeen\":" + ts + "}";
  LOG_INFO("[Heartbeat] Sending — lastSeen=%s", ts.c_str());
  firebaseRequest("PATCH", path.c_str(), json);
}

void writeOfflineStatus() {
  String path = String("devices/") + DEVICE_NAME;
  firebaseRequest("PATCH", path.c_str(), "{\"status\":\"offline\"}");
  LOG_INFO("[Firebase] Offline status written");
}

void reportAccidentToFirebase() {
  String path = String("accidents/") + DEVICE_NAME;
  String json = "{\"status\":\"ACCIDENT\","
                "\"device_id\":\"" + String(DEVICE_NAME) + "\","
                "\"timestamp\":\"" + getTimestamp() + "\","
                "\"latitude\":0,\"longitude\":0}";
  LOG_INFO("[Firebase] Reporting accident — %s", getTimestamp().c_str());
  if (!firebaseRequest("POST", path.c_str(), json)) {
    LOG_ERROR("[Firebase] Accident report failed");
  }
}

// ─── Accident Detection ─────────────────────────────────────────────────────

void resetDetection() {
  monitoring  = false;
  still_start = 0;
  impact_time = 0;
  stage       = 0;
}

void triggerAlarm() {
  LOG_INFO("[ACCIDENT] DETECTED — timestamp: %s", getTimestamp().c_str());
  reportAccidentToFirebase();
  startAlarm();
  last_trigger = millis();
}

void processAccidentDetection() {
  if (alarmActive) return;

  int16_t ax, ay, az, gx, gy, gz;
  mpu.getMotion6(&ax, &ay, &az, &gx, &gy, &gz);

  float total_g    = magnitude(ax / 16384.0f, ay / 16384.0f, az / 16384.0f);
  float total_gyro = magnitude(gx / 131.0f,   gy / 131.0f,   gz / 131.0f);

  if (!monitoring) baseline_g = 0.95f * baseline_g + 0.05f * total_g;

  float jerk = fabsf(total_g - prev_g) / (LOOP_DELAY_MS / 1000.0f);
  prev_g = total_g;

  // ── Periodic raw sensor log every 2s ────────────────────────────────────
  static uint32_t lastSensorLog = 0;
  if (millis() - lastSensorLog >= 2000) {
    lastSensorLog = millis();
    float spike = total_g - baseline_g;
    Serial.printf("[SENSOR] g=%.3f  base=%.3f  spike=%.3f  jerk=%.2f  gyro=%.1f  stage=%d  cooldown=%lums\n",
                  total_g, baseline_g, spike, jerk, total_gyro, stage,
                  millis() - last_trigger > COOLDOWN ? 0 : COOLDOWN - (millis() - last_trigger));
  }
  // ────────────────────────────────────────────────────────────────────────

  LOG_DEBUG("[MPU] g=%.3f gyro=%.1f jerk=%.2f base=%.3f stage=%d",
            total_g, total_gyro, jerk, baseline_g, stage);

  uint32_t now = millis();

  if (!monitoring) {
    if (now - last_trigger <= COOLDOWN) {
      LOG_DEBUG("[Detect] Cooldown — %lums remaining", COOLDOWN - (now - last_trigger));
      return;
    }
    float spike = total_g - baseline_g;
    if (spike > IMPACT_G && jerk > JERK_THRESHOLD && total_gyro < GYRO_IGNORE) {
      monitoring  = true;
      impact_time = now;
      still_start = 0;
      stage       = 1;
      LOG_INFO("[Detect] Stage 1 — IMPACT: spike=%.2fg jerk=%.1f gyro=%.1f", spike, jerk, total_gyro);
    }
    return;
  }

  if (stage == 1) {
    if (now - impact_time > WINDOW_TIME) {
      LOG_DEBUG("[Detect] Stage 1 expired — no confirmation, resetting");
      resetDetection();
      return;
    }
    stage = 2;
    LOG_DEBUG("[Detect] Stage 1 → 2");
  }

  if (stage >= 2) {
    bool isStill = (total_g < STILL_G && total_gyro < STILL_GYRO);

    if (isStill) {
      if (still_start == 0) {
        still_start = now;
        stage       = 3;
        LOG_INFO("[Detect] Stage 3 — still detected, waiting %lums", STILL_TIME);
      }
      uint32_t stillFor = now - still_start;
      LOG_DEBUG("[Detect] Still for %lums / %lums", stillFor, STILL_TIME);
      if (stillFor >= STILL_TIME) {
        LOG_INFO("[Detect] Still threshold met (%lums) — triggering!", stillFor);
        triggerAlarm();
        resetDetection();
      }
    } else {
      if (still_start != 0) {
        LOG_DEBUG("[Detect] Movement resumed — resetting still timer");
      }
      still_start = 0;
      if (now - impact_time > 15000) {
        LOG_WARN("[Detect] Monitoring timeout (15s) — resetting");
        resetDetection();
      }
    }
  }
}

// ─── Setup ──────────────────────────────────────────────────────────────────

void setup() {
  Serial.begin(115200);
  delay(200);

  Serial.println("\n──── CrashGuard ESP32 Boot ────");
  LOG_INFO("Free heap: %d bytes  CPU: %d MHz", ESP.getFreeHeap(), getCpuFrequencyMhz());

  // GPIO
  pinMode(BUZZER_PIN, OUTPUT); digitalWrite(BUZZER_PIN, LOW);
  pinMode(MOTOR_PIN,  OUTPUT); digitalWrite(MOTOR_PIN,  LOW);
  pinMode(LED_PIN,    OUTPUT); digitalWrite(LED_PIN,    LOW);
  LOG_INFO("GPIO — BUZZER:%d  MOTOR:%d  LED:%d", BUZZER_PIN, MOTOR_PIN, LED_PIN);

  // MPU6050
  Wire.begin(MPU_SDA, MPU_SCL);
  mpu.initialize();
  LOG_INFO("[MPU6050] Initialized on SDA:%d SCL:%d", MPU_SDA, MPU_SCL);

  // Calibrate baseline (30 samples)
  LOG_INFO("[MPU6050] Calibrating baseline...");
  for (int i = 0; i < 30; i++) {
    int16_t ax, ay, az, gx, gy, gz;
    mpu.getMotion6(&ax, &ay, &az, &gx, &gy, &gz);
    baseline_g = 0.95f * baseline_g + 0.05f * magnitude(ax / 16384.0f, ay / 16384.0f, az / 16384.0f);
    delay(100);
  }
  LOG_INFO("[MPU6050] Baseline: %.3fg", baseline_g);

  // Load saved credentials
  prefs.begin("crashguard", false);
  wifiSSID     = prefs.getString("ssid", "");
  wifiPassword = prefs.getString("pass", "");
  userId       = prefs.getString("uid",  "");

  if (wifiSSID.length() > 0) {
    LOG_INFO("[Prefs] Saved SSID: [%s]  UID: [%s]",
             wifiSSID.c_str(), userId.length() > 0 ? userId.c_str() : "(none)");
  } else {
    LOG_INFO("[Prefs] No credentials — provisioning mode");
  }

  // BLE always starts immediately — visible from first boot
  startBLE();

  Serial.println("──── CrashGuard Ready ────");
  LOG_INFO("BLE: [%s] visible now (%lus window)", DEVICE_NAME, BLE_WINDOW_MS / 1000);
  LOG_INFO("Send JSON via BLE: {\"ssid\":\"...\",\"pass\":\"...\",\"uid\":\"...\"}");
  LOG_INFO("Alarm: %lus  Cooldown: %lus  Debug: %d", ALARM_DURATION_MS / 1000, COOLDOWN / 1000, DEBUG_LEVEL);
  Serial.println("==========================================\n");
}

// ─── Loop ───────────────────────────────────────────────────────────────────

void loop() {
  handleBleLifecycle();
  handleWifiConnection();
  handleNtpSync();
  handleAlarm();
  handleLed();

  // Periodic heartbeat
  if (wifiConnected && firstHeartbeatSent && (millis() - lastHeartbeat > HEARTBEAT_MS)) {
    sendHeartbeat();
    lastHeartbeat = millis();
  }

  processAccidentDetection();
  delay(LOOP_DELAY_MS);
}
