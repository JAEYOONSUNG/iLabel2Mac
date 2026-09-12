# iLabel Studio

**🌐 Homepage: [jaeyoonsung.github.io/iLabel-Studio](https://jaeyoonsung.github.io/iLabel-Studio/)** · [한국어](https://jaeyoonsung.github.io/iLabel-Studio/ko/)

<img width="5128" height="2830" alt="iLabel Studio label editor" src="https://github.com/user-attachments/assets/d5e5a715-598e-4bdb-a431-95a3d428d587" />

`iLabel Studio` is a cross-platform precision label editor and printer built around **iLabel label sheets from `label.kr`**, while also supporting custom sheets and roll labels. It ships as a native SwiftUI app on macOS and as a feature-equivalent Electron app on Windows and Linux. Every edition shares the same project format, including rich text, embedded fonts, merge data, numbering, placement, and captured print queues.

## Download

Every release ships all three platforms from one page:

**https://github.com/JAEYOONSUNG/iLabel-Studio/releases/latest**

| Platform | File | Notes |
| --- | --- | --- |
| macOS (Apple Silicon and Intel) | `iLabel-Studio-macOS.dmg` | Developer-ID signed and notarized. Open the DMG, drag `iLabel Studio.app` to `Applications`, then launch it. |
| Windows 10/11 x64 | `iLabel-Studio-<version>-windows-x64-setup.exe` | Installer with in-app auto-update. |
| Windows 10/11 x64 | `iLabel-Studio-<version>-windows-x64-portable.exe` | Single file, no install. Updates are handed to you as a download. |
| Linux x64 | `iLabel-Studio-<version>-linux-x86_64.AppImage` | Run `chmod +x` once, then double-click or launch from a terminal. In-app auto-update. |
| Linux x64 (Debian/Ubuntu) | `iLabel-Studio-<version>-linux-amd64.deb` | `sudo apt install ./iLabel-Studio-<version>-linux-amd64.deb`. Updates are handed to you as a download. |

Windows builds are unsigned unless the repository's signing secrets are configured, so SmartScreen may ask you to confirm the first launch (**More info → Run anyway**).

Installed copies check for a new version on launch and every six hours, then offer it as an in-app card. Nothing downloads until you say so. The Windows installer and the Linux AppImage update in place through electron-updater; the macOS app downloads the DMG itself, verifies it against the SHA-256 the feed pins, swaps its bundle, and relaunches.

Upgrading from the former `iLabel2Mac.app`? Quit the old app, install `iLabel Studio.app`, then remove the old app bundle. Existing projects and saved app preferences remain compatible.

## What's new

**0.3.3**

- Right-click a captured label in the page preview to **Edit**, **Reposition**, or **Remove** that batch, or **Clear All Captures**. The queue actions no longer live only in the queue list.
- New projects start on the label stock you last worked with, whether an official format, a preset, or hand-edited geometry, instead of the factory format `680`.
- Wi-Fi printing keeps searching for the printer's network after you press **Print** and joins the moment it appears, so the queued job delivers automatically. The status bar shows the search, and the Connect test gets its own window.

**0.3.2**

- Captured setups can be edited: **Edit** checks a batch out of the queue and restores its label, numbering, CSV rows, and placement as the live draft. **Update Capture** returns it with the same identity, queue order, page, and offsets. **Cancel** restores the pre-edit snapshot untouched.
- Captured setups can be repositioned: **Reposition** arms a move mode in which the next click on an empty page slot carries the whole batch there. Conflicts with other captures are refused and the mode stays armed so you can pick another spot.

**0.3.0**

- Ask-first auto-update across all editions.
- Click-to-type and selection highlights in the Windows/Linux edition.

## Quick workflow: create a label and capture consecutive runs

![Create label content, adjust quantities, and capture multiple print runs](docs/assets/capture-queue-workflow.gif)

The light-theme demo uses the Windows/Linux edition. It adds a Text object, types `Sample {{serial}}`, switches to Page Preview, captures **8 labels** (`End 4 × Repeat 2`), then stages an empty position and captures **3 more labels** (`End 3 × Repeat 1`).

1. Add **Text**, enter the label content or merge tokens, then switch to **Page Preview**. The large label canvas shows exactly what each printed cell contains.
2. Set the quantity with **Start**, **End**, **Step**, and **Repeat**. With CSV data, one label is generated per imported row.
3. Click a label cell to choose where the run starts, then choose **Capture Current Setup**. The artwork, data, quantity, page, and start position are locked together.
4. Click another empty label cell to stage the next capture. Use **Next** if you want to start on a blank sheet; the capture button stays disabled until a valid position is staged.
5. Adjust the next run's quantity, then choose **Capture Current Setup** again.
6. Right-click a captured cell to edit, reposition, or remove that batch, then choose **Print Captures** to print the complete queue as one multi-page job.

## Features

- Native SwiftUI app for macOS and a feature-equivalent Electron app for Windows/Linux
- 1,006 official iLabel paper formats from `label.kr`, plus editable custom sheet/roll geometry; new projects open on your last-used stock
- Text, shape, image, QR, and Code128 elements
- Selection-level rich text: font, size, bold, italic, underline, and RGBA color
- macOS RTF compatibility and project-embedded TTF, OTF, WOFF, WOFF2, TTC, and OTC fonts
- Real installed-font metrics for line wrapping, including Korean text and merge tokens
- CSV merge tokens using `{{Column}}` and serial tokens using `{{serial}}`
- Capture queue that locks artwork, Numbering/CSV setup, page, and start position, then prints every capture in one multi-page job
- Captures can be edited, repositioned, reordered, and removed from the queue list or from the preview's right-click menu
- Full-circle text flow with chord-shaped lines and matching editor, preview, PDF, and print layout
- Page preview with per-slot merge rendering and rectangular drag selection
- macOS-matched three-pane layout, light/dark appearance, numbered page axes, and captured/next/overlap preview states
- JSON project save/load
- Exact-size PDF output and 720-DPI PNG output with physical-resolution metadata
- Windows print spool monitoring and Linux CUPS monitoring, with optional printer Wi-Fi switching that keeps searching for the printer's network and joins when it appears
- Ask-first in-app updates on every platform
- Sanitized SVG import and deterministic raster-image normalization
- Signed and notarized macOS DMG, Windows installer and portable builds, and Linux AppImage and `.deb` packages published on every release

## Notes

- CSV import accepts comma, tab, semicolon, and pipe-delimited files.
- Dynamic tokens supported in text, QR, and barcode fields:
  - `{{serial}}`
  - `{{serial_raw}}`
  - `{{set}}`
  - `{{index_in_set}}`
  - `{{page}}`
  - `{{slot}}`
  - `{{row}}`
  - `{{date}}`
  - `{{time}}`
  - `{{ColumnName}}`
- macOS and Windows/Linux use the same project JSON schema. Rich-text RTF runs, embedded fonts, images, CSV data, numbering, placement, and capture queues round-trip between editions.
- When a project is saved, the Windows/Linux edition collects a local font face only when its OS/2 license flags permit editable embedding. Existing project fonts are preserved; make sure you also have permission to redistribute them.
- Windows Wi-Fi switching uses `netsh`; Linux uses NetworkManager's `nmcli`. Leave it disabled for printers already reachable on the current network.
- Windows/Linux image import supports PNG, JPEG, WebP, BMP, GIF (first frame), and sanitized SVG. Unsupported TIFF/HEIC input is rejected with an explicit error instead of producing a blank label.
- Printer drivers can apply their own non-printable margins. For custom roll sizes, create/select the matching paper size in the Windows or CUPS driver before printing.

## Build from source

### macOS

```bash
swift build
swift test
scripts/build_app.sh     # universal (arm64 + x86_64) dist/iLabel Studio.app
scripts/package_dmg.sh   # wraps it in dist/iLabel-Studio-macOS.dmg
```

### Windows and Linux

The Electron edition lives in [`desktop/`](desktop/). Use Node.js 22.

```bash
cd desktop
npm ci
npm test
npm run dev            # development server plus Electron
npm run package:win    # run on Windows: NSIS installer and portable .exe
npm run package:linux  # run on Linux: AppImage and .deb
```

Every desktop change is also packaged and exercised by [the desktop workflow](.github/workflows/desktop.yml). It launches each packaged executable and verifies the renderer, preload bridge, 1,006-format catalog, rich text, embedded fonts, PDF dimensions, circular layout, placement selection, and capture queue. If you want a build ahead of the next release, open a successful run in [GitHub Actions](https://github.com/JAEYOONSUNG/iLabel-Studio/actions/workflows/desktop.yml) and download its `ilabel-studio-windows-x64` or `ilabel-studio-linux-x64` artifact. The Linux artifact wraps the AppImage in `tar.gz` so its executable permission survives download.

## Releasing

One command cuts a release for every platform:

```bash
node tools/release.mjs patch    # or minor, major, x.y.z; --dry to preview
```

It refuses a dirty tree or a failing suite, builds a Developer-ID-signed and notarized macOS DMG locally (Apple credentials stay in this keychain — store them once with `xcrun notarytool store-credentials ilabel`), bumps the version, pushes tag `vX.Y.Z`, and waits for [the Release workflow](.github/workflows/release.yml) to build the Windows/Linux packages into one GitHub release, then uploads the DMG beside them. Only then does it point `feed.json` on `gh-pages` at the new version and verify everything is publicly reachable. The feed moves last so no copy of the app is ever told about a build it cannot download.
