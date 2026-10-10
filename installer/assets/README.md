# Installer artwork

- `make_icons.py` (needs `pillow`) cuts `app-icon-source.png` into `app-icon.png` (1024, product icon; `build-app.sh` turns it into the Mac `AppIcon.icns`), `mac-icon.png` (512), `wolfleader.ico` and `wizard-small.bmp` (110x110, Inno `WizardSmallImageFile`).
- `render.py` (needs `playwright` + `pillow`) reads `app-icon.png` and `icons/` and renders the rest; it never writes the four files above. Run `make_icons.py` first.
- `wizard-side.bmp` (328x628, 24-bit, 2x of 164x314): Inno `WizardImageFile`, app icon over the "Wolf Leader" wordmark. `render.py`.
- `whatsnew-cards.bmp` (834x474) for the Inno "What's new" page at 417x237, and `whatsnew-cards.png` (1668x948) for the Mac dialog and README. `render.py`.
- `dmg-drag.png` (600x380) and `dmg-drag@2x.png` (1200x760): drag-to-Applications window background; app icon at (150, 190), Applications at (450, 190) in points. `make_dmg_background.py`.
