# Pane

Pane turns an Android tablet into a second Mac display. Windows drag onto it the way they drag onto any other screen. Touch on the tablet moves the Mac pointer, and the tablet can play the Mac's sound.

## What you need

- An Apple silicon Mac on macOS 14 or later
- Xcode Command Line Tools (`xcode-select --install` if `xcrun --show-sdk-path` fails)
- JDK 17 or later (`java -version`)
- The Android SDK, with `adb`. The usual place is `$HOME/Library/Android/sdk`. `brew install --cask android-platform-tools` also provides `adb`.
- A tablet on Android 8 or later, plugged in with a data USB-C cable, USB debugging on, and this computer accepted on the tablet's "Allow USB debugging" prompt

Pane does not connect over Wi-Fi. A USB 3 cable plugged straight into the Mac keeps motion even. A USB 2 cable or a hub still works, but large frames take longer to cross.

## Build a copy

Run these from the repo root.

```bash
# Mac app. The first build creates a local signing certificate. See Signing below.
mac/build.sh
open mac/dist/Pane.app

# Tablet app. The Gradle wrapper is already in the repo.
echo "sdk.dir=$HOME/Library/Android/sdk" > android/local.properties
android/gradlew -p android assembleDebug

# Install the tablet app. Use the adb that came with the SDK if it is not on your PATH.
"$HOME/Library/Android/sdk/platform-tools/adb" install -r android/app/build/outputs/apk/debug/app-debug.apk
```

If the SDK lives somewhere else, set `sdk.dir` to that path. The Mac app finds `adb` through `ADB`, then `ANDROID_HOME/platform-tools/adb`, then `$HOME/Library/Android/sdk/platform-tools/adb`, then Homebrew.

Open Pane on the Mac first, then Pane on the tablet. The Mac window should say the USB cable is ready before the tablet will connect.

Sound is optional and needs an administrator password:

```bash
mac/AudioDriver/install.sh
```

Then choose **Pane** in the Sound menu or System Settings › Sound › Output.

## First launch

macOS asks for two permissions:

- **Screen Recording**, so Pane can capture the virtual display
- **Accessibility**, so taps on the tablet can move the pointer

Quit Pane and open it again after turning Screen Recording on. macOS often ignores the grant until the app restarts.

The new display appears to the right of the main screen. If macOS asks what to show on it, choose extend. That choice is remembered.

With **Match tablet** selected, the display follows the tablet's screen. A dense panel is drawn Retina, so a Tab S9 is 2560×1600 pixels at 1280×800 points. The other sizes in the menu are fixed overrides. The refresh control is a cap: a 60 Hz tablet is not asked for 120.

120 Hz only adds frames when a real Mac screen runs at 120 Hz, such as a ProMotion MacBook display with the lid open. macOS draws the virtual display no faster than its fastest real screen, so a 60 Hz main display stays at 60. The tablet panel still switches to its own faster rate, which shortens the wait before each frame appears.

## Touch

- Tap to click. Tap twice to double-click.
- Drag a finger to scroll. A flick keeps scrolling.
- Press and hold until the tablet buzzes, then drag. That holds the mouse button, for moving windows or selecting text.
- Tap with two fingers to right-click. Dragging two fingers also scrolls.
- Spread or pinch two fingers to zoom, the same as a trackpad pinch. It zooms the active window, so click into a window first if it does not respond.
- A stylus, on a tablet that has one, is a precise pointer. Hover moves the pointer, touching clicks and drags, and the side button right-clicks.
- Back disconnects.

## Sound

`mac/AudioDriver/install.sh` adds a **Pane** output device, asks for an administrator password, and restarts Core Audio for about a second. The Mac's volume keys control it. Choose your usual output to hear sound on the Mac again.

The first time, macOS asks to let Pane capture audio from other apps. Allowing that keeps sound close to the picture. Denying it still plays sound, noticeably later.

To remove the driver:

```bash
sudo rm -rf /Library/Audio/Plug-Ins/HAL/PaneAudio.driver && sudo killall coreaudiod
```

The Pane output stays in the Sound list when the tablet is unplugged. Choosing it then plays nothing.

## Signing

`mac/build.sh` signs the app with a certificate named **Pane Local Signing**. The first build creates it in the login keychain with `mac/setup-signing.sh`. The private key stays on that Mac and is not part of this repo. Each person who builds Pane gets their own certificate.

Screen Recording stays granted across later rebuilds because the signature does not change. If the certificate cannot be created, the build is signed ad-hoc and macOS asks for Screen Recording again after every build.

Set `PANE_SIGNING_IDENTITY` to sign with a different certificate name.

## Limits

- The virtual display uses a private macOS API (`CGVirtualDisplay`). Pane cannot ship in the App Store, and a future macOS could break it.
- The picture is H.264 over the USB debugging connection, not a raw video signal. Capture, encode, and decode add a frame or two. The pointer is drawn on the tablet from the Mac's cursor, so it moves ahead of the picture.
- One tablet at a time. If two are plugged in, Pane uses the first one `adb` lists.
- The Mac app is built for Apple silicon only. The audio driver is built for both Apple silicon and Intel.
- Sound plays about 60 ms after the Mac produces it. The picture is closer to 30 ms.
- A stylus reports pressure, but Mac apps that only understand a mouse treat it as a click.

## Timing logs

Both apps can log per-second timings. Restart both after changing either setting.

```bash
defaults write app.pane.mac pane.stats -bool YES
"$HOME/Library/Android/sdk/platform-tools/adb" shell setprop log.tag.PaneStats DEBUG
```

The Mac writes `/tmp/pane-stats.log`. The tablet logs with `adb logcat -s PaneStats`.

Turn them off:

```bash
defaults delete app.pane.mac pane.stats
"$HOME/Library/Android/sdk/platform-tools/adb" shell setprop log.tag.PaneStats '""'
```

## License

Pane is source-available under the MIT License with the Commons Clause. You may use it in a business, change it, and share it. You may not sell it, or charge for a product whose value is mostly Pane. The terms are in [LICENSE](LICENSE).

The Gradle wrapper scripts, `android/gradlew` and `android/gradlew.bat`, stay under the Apache License 2.0.

## Tests

These check the parser, the Retina choice, touch decisions, and the audio buffer. They do not need the tablet.

```bash
# Quit Pane first. The Mac check also creates a temporary virtual display.
mac/dist/Pane.app/Contents/MacOS/Pane --self-test

android/gradlew -p android test
```

## Notes for a build agent

Follow **Build a copy** above. Do not invent a second install path.

- Run commands from the repo root. `mac/build.sh` and `android/gradlew` find their own directories.
- The Mac app target is `arm64-apple-macos14.0`. Leave it there unless the task is an Intel build.
- Do not run `gradle wrapper`. `android/gradlew` and `android/gradle/wrapper` are already in the repo (Gradle 8.9, Android Gradle Plugin 8.5.2, Kotlin 1.9.25). The app's `minSdk` is 26, `compileSdk` is 34, `targetSdk` is 33, and the application id is `app.pane.tablet`.
- `android/local.properties` is gitignored. Create it locally. Do not commit it, `mac/dist`, `mac/.build`, Android build outputs, or an APK.
- Do not commit a signing key. `security find-identity -p codesigning -v` hides Pane Local Signing because it is a private certificate (`CSSMERR_TP_NOT_TRUSTED`). That result is expected. The build checks the list without `-v`, and `codesign` accepts the certificate.
- Quit Pane before `mac/dist/Pane.app/Contents/MacOS/Pane --self-test`. A second copy cannot create the virtual display while one already exists. Success prints `self-test ok`.
- The picture, pointer, and audio stay on USB. The Mac listens on `127.0.0.1` ports 47777, 47778, and 47779, and creates `adb reverse` tunnels for them. Do not add Wi-Fi or Bonjour.
- Skip `mac/AudioDriver/install.sh` unless sound was requested. It opens an administrator password dialog and restarts Core Audio.
- The project license is MIT with the Commons Clause, in `LICENSE`. Leave that file as it is. `android/gradlew` and `android/gradlew.bat` stay under Apache 2.0.
