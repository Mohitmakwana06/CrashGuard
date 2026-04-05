# CrashGuard — Setup Guide

Complete instructions for setting up and running the CrashGuard accident detection system.

---

## 📋 Prerequisites

- Flutter SDK 3.10+ installed
- Android device or emulator (API 23+)
- Firebase account (free tier is fine)
- Twilio account (for SMS — optional for testing alerts)
- ESP32 with WiFi capability (for production use)

---

## 🔥 Step 1: Firebase Setup

### 1.1 Create Firebase Project

1. Go to [Firebase Console](https://console.firebase.google.com)
2. Click **Add Project** → name it (e.g., "CrashGuard")
3. Disable Google Analytics (optional)
4. Click **Create Project**

### 1.2 Add Android App

1. In the project, click **Add App** → Android
2. Package name: `com.example.crash_guard`
3. App nickname: "CrashGuard"
4. Download `google-services.json`
5. **Place `google-services.json` in:** `android/app/google-services.json`

> ⚠️ **CRITICAL:** The app will NOT compile without this file!

### 1.3 Enable Realtime Database

1. In Firebase Console → **Build** → **Realtime Database**
2. Click **Create Database**
3. Choose your region
4. Start in **Test Mode** (for development)
5. Set these rules for production:

```json
{
  "rules": {
    "accidents": {
      "$device_id": {
        ".read": true,
        ".write": true,
        "$timestamp": {
          ".validate": "newData.hasChildren(['status', 'latitude', 'longitude', 'timestamp', 'device_id'])"
        }
      }
    }
  }
}
```

### 1.4 Enable Cloud Messaging (FCM)

1. In Firebase Console → **Build** → **Cloud Messaging**
2. FCM is enabled by default for new projects
3. No additional setup needed — the app handles token management

---

## 📱 Step 2: Twilio Setup (for SMS)

### 2.1 Create Twilio Account

1. Go to [Twilio Console](https://console.twilio.com)
2. Sign up for a free trial
3. Verify your phone number

### 2.2 Get Credentials

1. From the Twilio Console dashboard, copy:
   - **Account SID**
   - **Auth Token**
   - **Twilio Phone Number** (from Phone Numbers section)

### 2.3 Configure in App

Edit `.env` in the project root:

```env
TWILIO_ACCOUNT_SID=ACxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
TWILIO_AUTH_TOKEN=your_auth_token_here
TWILIO_PHONE_NUMBER=+1234567890
LINKED_DEVICE_ID=ESP32_001
```

> 📝 **Note:** Twilio trial accounts can only send SMS to verified numbers. Add your test numbers in Twilio Console → Verified Caller IDs.

---

## 🔧 Step 3: ESP32 Configuration

### 3.1 Expected Firebase Data Format

Your ESP32 should write to:
```
accidents/{device_id}/{timestamp}
```

Example path: `accidents/ESP32_001/2025-01-15T10:30:00Z`

With this JSON payload:
```json
{
  "status": "ACCIDENT",
  "latitude": 28.6139,
  "longitude": 77.2090,
  "timestamp": "2025-01-15T10:30:00Z",
  "device_id": "ESP32_001"
}
```

### 3.2 Device ID Linking

- The `LINKED_DEVICE_ID` in `.env` must match the `device_id` your ESP32 writes
- The app only listens to events from this specific device
- Default is `ESP32_001`

### 3.3 ESP32 Arduino Sketch (Example)

```cpp
#include <WiFi.h>
#include <Firebase_ESP_Client.h>
#include <time.h>

// WiFi
#define WIFI_SSID "YourWiFi"
#define WIFI_PASSWORD "YourPassword"

// Firebase
#define FIREBASE_HOST "your-project.firebaseio.com"
#define FIREBASE_AUTH "your-database-secret"

#define DEVICE_ID "ESP32_001"

FirebaseData fbdo;
FirebaseAuth auth;
FirebaseConfig config;

void sendAccident(float lat, float lng) {
  // Get current time
  struct tm timeinfo;
  getLocalTime(&timeinfo);
  char timestamp[30];
  strftime(timestamp, sizeof(timestamp), "%Y-%m-%dT%H:%M:%SZ", &timeinfo);

  String path = "/accidents/" + String(DEVICE_ID) + "/" + String(timestamp);

  FirebaseJson json;
  json.set("status", "ACCIDENT");
  json.set("latitude", lat);
  json.set("longitude", lng);
  json.set("timestamp", timestamp);
  json.set("device_id", DEVICE_ID);

  Firebase.RTDB.setJSON(&fbdo, path.c_str(), &json);
}
```

---

## 🚀 Step 4: Running the App

### 4.1 Install Dependencies

```bash
cd crash_guard
flutter pub get
```

### 4.2 Generate Hive Adapters

```bash
flutter pub run build_runner build --delete-conflicting-outputs
```

### 4.3 Run on Device

```bash
flutter run
```

> ⚠️ **Use a physical device** for full testing — emulators don't support vibration, alarm sounds, or reliable background services.

---

## 🧪 Step 5: Testing the Accident Flow

### Test 1: Cloud Test (via Firebase)

1. Open the app
2. Wait for "Connected via Cloud" banner
3. Tap **Cloud Test** button
4. This writes a test accident to Firebase
5. The app should detect it and show the full-screen alert
6. Verify: alarm sound + vibration + countdown
7. Tap "I'm Safe" to dismiss

### Test 2: Local Test (no Firebase)

1. Tap **Local Test** button
2. Alert appears immediately (no Firebase roundtrip)
3. Verify same behavior: alarm + vibration + countdown
4. Let countdown expire to test SMS sending

### Test 3: Firebase Console Manual Write

1. Go to Firebase Console → Realtime Database
2. Navigate to `accidents/ESP32_001/`
3. Add a new child with key = current ISO timestamp
4. Add these children:
   - `status`: "ACCIDENT"
   - `latitude`: 28.6139
   - `longitude`: 77.2090
   - `timestamp`: (same as the key)
   - `device_id`: "ESP32_001"
5. The app should trigger an alert

### Test 4: Background Detection

1. Open the app, wait for "Connected via Cloud"
2. Press Home (background the app)
3. Write a test accident to Firebase (via Console)
4. A notification should appear
5. Tapping the notification opens the alert screen

### Test 5: SMS Delivery

1. Configure Twilio credentials in `.env`
2. Add an emergency contact with a verified phone number
3. Trigger an accident and let the countdown expire
4. Check that the SMS arrives with the Google Maps link

---

## ❗ Common Issues & Fixes

### "google-services.json not found"
→ Download from Firebase Console and place in `android/app/`

### "Firebase not initialized"
→ Ensure `await Firebase.initializeApp()` runs before any Firebase calls

### Notification not showing
→ Check that notification permissions are granted
→ On Android 13+, POST_NOTIFICATIONS permission must be explicitly granted

### Alarm sound not playing
→ Ensure `assets/sounds/alarm.wav` exists
→ Check device volume is not muted
→ The `audioplayers` package requires the asset to be in the `assets/` folder

### Background service killed by OS
→ Disable battery optimization for CrashGuard in device settings
→ On Xiaomi/MIUI: Settings → Apps → CrashGuard → Battery Saver → No restrictions
→ On Samsung: Settings → Apps → CrashGuard → Battery → Unrestricted

### SMS not sending
→ Verify Twilio credentials in `.env`
→ On Twilio trial: recipient number must be verified in Twilio Console
→ Check internet connectivity
→ Check Twilio account balance

### Location unavailable
→ Enable GPS on the device
→ Grant location permissions (including "Always Allow" for background)
→ Try outdoors for better GPS signal

### Build error: minSdkVersion
→ Ensure `minSdk = 23` in `android/app/build.gradle.kts`

### Duplicate alerts
→ The debounce window is 30 seconds — events within this window are ignored
→ Check that your ESP32 isn't writing multiple events rapidly

---

## 📁 Project Structure

```
lib/
├── main.dart                          # Entry point + Firebase listener
├── core/
│   ├── app_theme.dart                 # Light/dark Material 3 themes
│   ├── constants.dart                 # All magic values
│   ├── env_config.dart                # .env reader (Twilio + device ID)
│   └── theme_provider.dart            # Riverpod theme mode
├── models/
│   ├── accident_event.dart            # ESP32 accident data model
│   ├── contact_model.dart             # Emergency contact (Hive)
│   └── contact_model.g.dart           # Generated Hive adapter
├── services/
│   ├── alarm_service.dart             # Looping alarm sound (audioplayers)
│   ├── alert_service.dart             # Alert lifecycle orchestration
│   ├── background_service.dart        # Foreground service (keep-alive)
│   ├── fcm_service.dart               # Firebase Cloud Messaging
│   ├── firebase_service.dart          # RTDB listener + debounce
│   ├── location_service.dart          # GPS via Geolocator
│   ├── notification_service.dart      # Local notifications (full-screen)
│   ├── permission_service.dart        # Runtime permission requests
│   └── sms_service.dart               # Twilio SMS with retry
└── features/
    ├── accident/
    │   ├── accident_provider.dart      # Status + last event + connection
    │   └── dashboard_screen.dart       # Home screen with status + tests
    ├── alert/
    │   ├── alert_provider.dart         # Countdown state
    │   └── alert_screen.dart           # Full-screen emergency UI
    └── contacts/
        ├── add_contact_dialog.dart     # Add/edit contact form
        ├── contacts_provider.dart      # Contacts CRUD provider
        ├── contacts_repository.dart    # Hive persistence
        └── contacts_screen.dart        # Contacts list screen
```
