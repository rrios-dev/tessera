# Tessera brand

**Mark:** three tiles whose gaps draw a **T** — windows in a mosaic, and the initial in the space
between them. **Wordmark:** "tessera" in Geist Medium, lowercase, tracking −0.045 em, outlined.
Black `#0a0a0a` and white only.

| File | Use |
|---|---|
| `app-icon.svg`, `AppIcon.icns` | macOS app icon (Apple's 1024 grid, 824 body, hairline edge for dark backgrounds) |
| `app-icon-light.svg` | Light variant, for documents on dark backgrounds |
| `mark.svg`, `mark-white.svg` | The mark alone, transparent |
| `wordmark.svg`, `wordmark-white.svg` | The name alone |
| `lockup.svg`, `lockup-white.svg` | Mark + name, transparent |
| `lockup-on-dark.svg`, `lockup-on-light.svg` | Mark + name on their background, with clear space |
| `png/` | Raster exports (1x and 2x) |

The menu bar icon is drawn in code from the same geometry (`Sources/TesseraAppUI/BrandMark.swift`)
as a template image: filled while tiling, outlined while paused.

**Rules.** Keep clear space of one mark height around a lockup. In a lockup the mark is 1.13 × the
type size and sits 0.4 × the type size from the name. Never recolour the tiles individually, never
stretch, never set the name in another typeface.

**Regenerate.**

```bash
npm pack geist@1.7.2 && tar xzf geist-1.7.2.tgz
python3 assets/brand/generate.py package/dist/fonts/geist-sans/Geist-Medium.ttf
assets/brand/make-icons.sh
```

Geist © Vercel, SIL Open Font License 1.1 (`GEIST-LICENSE.txt`); the outlines embedded in the
wordmark are covered by it.
