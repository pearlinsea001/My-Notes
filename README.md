# My Notes (Flutter / Android)

## Build in 4 steps
1. Install Flutter: https://docs.flutter.dev/get-started/install
2. Unzip this folder, open a terminal inside it.
3. Run `./setup.sh`   (Windows: run the commands inside setup.sh by hand)
4. `flutter build apk --release`  ->  build/app/outputs/flutter-apk/app-release.apk

`setup.sh` creates the Android project, sets the app name to "My Notes", adds the manifest entries
(file provider, share-to-app, image cropper, camera lookup) and writes the native Kotlin code.
Codemagic users: just push this folder, `codemagic.yaml` runs `setup.sh` for you.

## How it works
- Floating + button (bottom-right) -> Add Button / Add Note / Add File / Camera / Backup.
- Camera opens the phone camera; the photo is added to the page you are on.
- Each button opens its own page with the same layout and + menu (nesting is unlimited).
- Files are copied into the app's private documents folder (not cache); the picker's temp copy is deleted.
- Tap a picture -> built-in viewer (pinch to zoom). Crop / Edit opens the cropper (crop, rotate, aspect ratio);
  Revert puts the original back while the viewer is still open.
- Tap any other file -> opens in the default app. Menu (3 dots) -> Open with..., Edit, Share, Copy, Delete.
- Edit (file) -> rename, colour (shown as the file icon) and transparency (tints the whole tile, like notes).
- Backup -> Create: zip saved to Downloads/My Notes Backup (<date>).zip.
  Restore: pick that zip. Its contents are added BELOW your existing items; nothing existing is changed.
- During backup / restore the + button fills with bubbles from bottom to top.
