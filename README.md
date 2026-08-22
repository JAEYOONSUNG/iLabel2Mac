# iLabel2

<img width="5128" height="2830" alt="iLabel2 label editor" src="https://github.com/user-attachments/assets/d5e5a715-598e-4bdb-a431-95a3d428d587" />

`iLabel2` is a precision label editor and printer for `label.kr`-style sheets and custom roll labels. It ships as a native SwiftUI app on macOS and as a feature-equivalent Electron app on Windows and Linux. The editions share the same project format, including rich text, embedded fonts, merge data, numbering, placement, and captured print queues.

## Install on macOS

Download `iLabel2Mac.dmg` from the latest release:

https://github.com/JAEYOONSUNG/iLabel2Mac/releases/latest

Open the DMG, drag `iLabel2Mac.app` to `Applications`, then launch it.

## Install on Windows and Linux

Windows and Linux packages are built from [`desktop/`](desktop/):

- Windows x64: NSIS installer and portable `.exe`
- Linux x64: AppImage and Debian `.deb`

Every desktop change is packaged and exercised by [the desktop workflow](.github/workflows/desktop.yml). Open a successful run in [GitHub Actions](https://github.com/JAEYOONSUNG/iLabel2Mac/actions/workflows/desktop.yml) and download its `ilabel2-windows-x64` or `ilabel2-linux-x64` artifact:

- Windows: choose the NSIS setup `.exe` or the standalone portable `.exe`.
- Linux: choose the AppImage `.tar.gz` or Debian `.deb` package.

The Linux artifact wraps the AppImage in `tar.gz` so its executable permission survives download. Windows development artifacts are unsigned unless the repository's `WIN_CSC_LINK` and `WIN_CSC_KEY_PASSWORD` secrets are configured, so Windows may show a SmartScreen warning.

To build locally:

```bash
cd desktop
npm ci
npm test
npm run package:win    # run on Windows
npm run package:linux  # run on Linux
```

For development, use Node.js 22 and run `npm run dev` in `desktop/`. The workflow launches each packaged executable—not only the development server—and verifies the renderer, preload bridge, 1,006-format catalog, rich text, embedded fonts, PDF dimensions, circular layout, placement selection, and capture queue before publishing artifacts.

## Features

- Native SwiftUI app for macOS and a feature-equivalent Electron app for Windows/Linux
- 1,006 official `label.kr` formats, sheet presets, and editable custom sheet/roll geometry
- Text, shape, image, QR, and Code128 elements
- Selection-level rich text: font, size, bold, italic, underline, and RGBA color
- macOS RTF compatibility and project-embedded TTF, OTF, WOFF, WOFF2, TTC, and OTC fonts
- Real installed-font metrics for line wrapping, including Korean text and merge tokens
- CSV merge tokens using `{{Column}}` and serial tokens using `{{serial}}`
- Capture queue that locks artwork, Numbering/CSV setup, page, and start position, then prints every capture in one multi-page job
- Full-circle text flow with chord-shaped lines and matching editor, preview, PDF, and print layout
- Page preview with per-slot merge rendering and rectangular drag selection
- JSON project save/load
- Exact-size PDF output and 720-DPI PNG output with physical-resolution metadata
- Windows print spool monitoring and Linux CUPS monitoring, with optional printer Wi-Fi switching only when the current network cannot drain the job
- Sanitized SVG import and deterministic raster-image normalization
- Windows/Linux installer builds and packaged-app smoke screenshots generated in CI

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
