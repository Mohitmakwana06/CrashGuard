# 🚀 CrashGuard Features

CrashGuard is a high-reliability accident detection and emergency response system built with Flutter and ESP32. Below are the key features and capabilities currently implemented in the application.

---

## 🛰️ Real-time Detection & Connectivity
- **ESP32 Integration**: Seamless monitoring of accidents via Firebase Realtime Database.
- **Cloud Connectivity**: Proactive connection status banners (Green: Connected, Red: Offline).
- **Firebase Authentication**: Secure user login and multi-device support.
- **BLE Provisioning**: Built-in Bluetooth Low Energy (BLE) tools to provision WiFi credentials and User ID to ESP32 devices.

---

## 🚨 Emergency Alert System
- **Full-Screen Emergency UI**: Immediate high-visibility overlay when an accident is detected.
- **High-Intensity Alarm**: Looping, high-volume alarm sound to alert bystanders.
- **Dynamic Countdown**: Customizable 30-second countdown for the user to confirm they are safe.
- **Haptic Feedback**: Persistent vibration alerts during the emergency alert phase.
- **"I'm Safe" Override**: One-tap cancellation to prevent false alarms from sending SMS.

---

## 📩 Automated Emergency Response
- **Twilio SMS Integration**: Automated SMS dispatch to all emergency contacts when the countdown expires.
- **GPS Location Sharing**: Real-time GPS coordinates and a Google Maps link included in help messages.
- **Message Retry Logic**: Intelligent retry system for SMS delivery if the first attempt fails.
- **Redundancy**: Dual-path alerting via Firebase Cloud Messaging (FCM) and local notification triggers.

---

## 🛠️ Diagnostics & Reliability
- **Cloud Test Mode**: Simulate a Firebase accident event to verify the full cloud-to-device pipeline.
- **Local Test Mode**: Instant UI/Alarm/SMS test to verify local device capabilities (Vibration, Audio, SMS).
- **Foreground Service**: Persistent background execution on Android to ensure detection works even if the app is minimized.
- **Permission Guard**: Smart runtime permission handling for Location, SMS, Notifications, and Bluetooth.

---

## 📇 Data & Management
- **Emergency Contacts**: Local-first storage using Hive for lightning-fast access to trusted contacts.
- **Material 3 Design**: Modern, premium UI with support for dynamic Light and Dark modes.
- **Riverpod State Management**: Robust and predictable application state throughout the alert lifecycle.

---

## 📁 Technical Roadmap
- [x] Firebase Realtime Database Sync
- [x] Twilio SMS Gateway
- [x] ESP32 BLE Provisioning
- [x] Background Foreground Service
- [x] GPS-Linked Alerts
- [ ] AI-based Crash Severity Assessment (Future)
- [ ] Dashcam Integration (Future)
