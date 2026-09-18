# Reply to App Review — Guideline 2.1 (Information Needed)

Paste into **both**:
- App Store Connect → the Messages thread on the rejection
- App Store Connect → App Review Information → **Notes**

Before sending: fill in the video URL.

---

Hello,

Happy to clarify. **Daily Meds has no account system and makes no network requests** — no server, no analytics, no third-party SDKs. Everything runs on the device.

**Demo credentials:** none needed. The app opens with every feature unlocked on first launch. Nothing is gated, no sign-in, no in-app purchases. Since no account is ever created, there is also no account-deletion flow.

**Data:** medication names, schedules and dose history are stored locally and used only for reminders and history. Nothing is transmitted or shared. App Privacy is set to "Data Not Collected", and the bundled privacy manifest declares no collected data types and no tracking.

**Health app:** on iOS 26+, an optional one-tap import of the user's medication list. Read-only — the app never writes back to Health. Access goes through Apple's per-medication picker, and the app works fully without it.

**Camera:** optional, only on tap. Text recognition runs on device via Vision. No image is saved or uploaded, and every scanned field is shown for review before saving.

**What the app does:** Daily Meds reminds people to take medication they have already been prescribed, logs whether they took it, and counts down how much they have left so they know before they run out. The camera scan reads what is already printed on a box or pharmacy label so they do not have to type it in. The app does not diagnose, does not recommend or calculate doses, and does not give medical advice — it records what the user enters and reminds them at the times they set.

Screen recording of the full flow: [PASTE URL]

Support: support@figoodle.com

Best regards,
Amir
