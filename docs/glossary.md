# Glossary (product language)

One word per thing, in both languages (audit E10). The strings live in `L10n` in the engine,
Spanish and English side by side.

| Concept | Español | English | Never |
|---|---|---|---|
| A Mission Control desktop (native Space) | Escritorio | Desktop | "Espacio" for a desktop |
| A native full-screen Space | Pantalla completa de macOS | macOS full screen | — |
| One of Tessera's emulated workspaces inside a desktop | Grupo | Group | "Espacio", "workspace" in the UI |
| Tessera covering the desktop with one window | Pantalla completa de Tessera | Tessera full screen | "zoom" in the UI |
| Layout: side by side / stacked | Mosaico | Tiles | — |
| Layout: overlapping strips | Acordeón | Accordion | — |
| Layout: one window at a time | Maximizado | Maximized | "monocle" in the UI (CLI keeps `monocle`) |
| Stop placing windows, keep running | Pausar / Reanudar | Pause / Resume | — |
| Bring every hidden window back | Reunir todas las ventanas | Gather all windows | — |
| Undo Tessera's first arrangement | Revertir a la disposición original | Revert to the original layout | — |
| Crash-loop protection | Modo seguro | Safe mode | — |

The CLI keeps AeroSpace's command names (`workspace`, `monocle`, `move-node-to-workspace`) for
compatibility; everything a person reads on screen uses the words above.
