# iLabel2Mac
<img width="5128" height="2830" alt="image" src="https://github.com/user-attachments/assets/d5e5a715-598e-4bdb-a431-95a3d428d587" />

`iLabel2Mac` is a native macOS label editor and printer for `label.kr`-style sheets and roll labels.

## Install

Download `iLabel2Mac.dmg` from the latest release:

https://github.com/JAEYOONSUNG/iLbael2Mac/releases/latest

Open the DMG, drag `iLabel2Mac.app` to `Applications`, then launch it.

## Features

- Native `SwiftUI` desktop app for macOS
- Official `label.kr` format catalog
- Sheet presets and editable custom page/label geometry
- Text, shape, image, QR, and Code128 elements
- CSV merge tokens using `{{Column}}`
- Serial tokens using `{{serial}}`
- Capture queue that locks artwork, Numbering/CSV setup, page, and start position, then prints every capture in one multi-page job
- Full-circle text flow with chord-shaped lines and matching editor, preview, PDF, and print layout
- Page preview with per-slot merge rendering
- JSON project save/load
- PDF, PNG, and print output for the current page

## Notes

- CSV import accepts comma, tab, semicolon, and pipe-delimited files.
- Dynamic tokens supported in text, QR, and barcode fields:
  - `{{serial}}`
  - `{{page}}`
  - `{{slot}}`
  - `{{row}}`
  - `{{date}}`
  - `{{ColumnName}}`
