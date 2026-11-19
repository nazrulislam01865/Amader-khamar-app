# Amader Khamar - launcher icon setup

Source image: `branding/Farming_App_Logo.png` (original RGBA PNG, 1024 x 1024).

The current launcher assets are already generated. Android uses the existing
`android:icon="@mipmap/ic_launcher"` reference; no change to `AndroidManifest.xml`
is required. Android 8.0+ uses the adaptive icon layer in
`android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml`; earlier Android
versions use the mipmap PNGs. The icon is also updated for the Flutter web
favicon/install icons and existing Windows icon. No Flutter code, dependency,
permissions or version changes are involved.

The icon uses a white background to preserve the original green leaf/checkmark
colors. The adaptive foreground is sized for common launcher mask safe zones.

To regenerate after changing the source logo:

```sh
python3 -m pip install Pillow
python3 tools/generate_app_icons.py
```

To check the Android launcher on a device:

```sh
flutter clean
flutter pub get
flutter run
```

For a Play Store release, build your signed AAB using the project's existing
release-signing configuration and submit `branding/play_store_icon_512.png`
separately as the Play Store *listing* icon. The launcher icon is compiled into
the Android application automatically. A full app rebuild and reinstall may be
needed because launchers sometimes cache icons.

This project archive has no `ios/` folder, so no iOS icon assets were created.
