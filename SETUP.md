# Locus — install & first teleport

## 1. Sideload the IPA

Install the latest IPA from [Releases](https://github.com/ChrisMack32/Locus/releases) (or [build from the active development branch](README.md#development)) with Feather, SideStore, AltStore, Sideloadly, or LiveContainer.

Bundle ID: `com.chrismack.locus`

### LiveContainer

File pickers often break inside LiveContainer. Do one of the following:

1. Long-press **Locus** in LiveContainer → **Settings** → enable **Fix File Picker**, then try Import again.
2. Share / open the pairing file **into LiveContainer → Locus** (iOS share sheet).
3. Copy the RPPairing plist contents, open Locus → **Paste RPPairing from clipboard** (setup or Settings).

## 2. Pairing

### On iOS 27 — no computer

1. Open Locus → **Settings → Pair on this iPhone** → **Start pairing**.
2. Allow **Local Network** (and Location / Notifications if asked).
3. Leave Locus open. Go to **Settings › Privacy & Security › Developer Mode › Pair with Host**.
4. Pick **Locus** → **Pair**.
5. Enter your **iPhone unlock passcode** first (authorizes pairing).
6. When the second prompt appears, type the **6-digit code** Locus shows (also sent as a notification).
7. Done — RPPairing file is saved on-device.

### On iOS 18–26

1. On a computer, download [idevice_pair](https://github.com/jkcoxson/idevice_pair/releases).
2. Plug in your iPhone, unlock, Trust.
3. Generate an **RPPairing** file (not lockdown / SideStore `.mobiledevicepairing`).
4. AirDrop / Share → Open in **Locus**, **Import**, or **Paste from clipboard**.

## 3. LocalDevVPN

Install [LocalDevVPN](https://apps.apple.com/us/app/localdevvpn/id6755608044), connect it (default tunnel IP `10.7.0.1`).

## 4. Teleport

Search or drop a pin, then tap **Teleport To**. The **Active** indicator follows successful responses from the location service. Settings → Advanced shows the observed network path and last connection error.

### Start without Wi-Fi

1. Connect LocalDevVPN while Cellular Data is on. Plan your route while you still have internet access.
2. If the simulation cannot connect, turn off **Cellular Data** while leaving LocalDevVPN connected. Retry **Teleport To** or let the active drive retry. If the drive paused, tap **Resume**.
3. Wait for Locus to show **Active**, then turn Cellular Data back on. If the session drops, you may need to repeat the sequence.

This startup sequence is reported for other apps using LocalDevVPN and can vary by device and iOS version. [Roam Control mobile-data guide](https://github.com/seanhowarthdev/Roam-Control/blob/main/Documentation/UserGuide.md#mobile-data-connection-flow)
