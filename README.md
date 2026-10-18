<p align="center">
  <img src="docs/icon.png" alt="Peeky Folders app icon: a frosted glass folder with a translucent pink heart, two more folders fanned out behind it, on a blue gradient" width="128">
</p>

<h1 align="center">Peeky Folders</h1>

<p align="center"><b>Press Space on a folder or archive in Finder and see what's inside.</b></p>

<p align="center">
  <img src="docs/screenshots/icons.png" alt="Peeky Folders showing a Photos folder in icon view, with thumbnails and file sizes" width="720">
</p>

> [!NOTE]
> Vibe coded with [Claude Code](https://claude.com/claude-code), with me directing and testing.

## Features

- Quick Look for **folders and archives**: zip, tar, gz, 7z, rar, xz, bz2, jar and more
- **List and icon views** with thumbnails, sizes, dates and kinds
- **Folder sizes** calculated in the background
- **Browse into subfolders**, copy items or their paths

## Install

Requires macOS 13 or later (Apple silicon or Intel).

1. Download **PeekyFolders-x.y.zip** from the [latest release](https://github.com/kaichn/peeky-folders/releases/latest)
   and move **Peeky Folders.app** to Applications.
2. Open it. Because the app isn't notarized, macOS blocks it the first time: go to
   System Settings → Privacy & Security and click **Open Anyway**
   (or run `xattr -dr com.apple.quarantine "/Applications/Peeky Folders.app"`).
3. Follow the welcome window: turn on the extension under
   System Settings → General → Login Items & Extensions → **Quick Look**.
4. Select a folder in Finder and press **Space**.

## Build from source

Needs Xcode 26 or later.

```bash
git clone https://github.com/kaichn/peeky-folders.git
cd peeky-folders
./build.sh install
```

## License

[MIT](LICENSE) © 2026 Carl Chen. Inspired by [Folder Preview](https://apps.apple.com/app/folder-preview/id6698876601).
