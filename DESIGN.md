# DESIGN.md: ColorDisco Pro Video Color Grader

## 1. Design Read & Identity
Reading this as: Professional Video Color Grading Studio for Apple Ecosystem Creators and Colorists, in an iOS 26 Liquid Glass + Utilitarian Swiss Darkroom style, dial ENERGY 1 / RHYTHM 2 / MOTION 1.

- **Product Identity**: Studio-grade, offline-first color grading tool for iPhone (iOS), iPad (iPadOS), and Mac (macOS).
- **Design System Composition (`@samios`)**:
  - **90% Primary (`@samios` iOS 26 Kit)**: Native `.ios-surface`, `ios.css` components (`Status Bar`, `Navigation Bar`, `Liquid Glass` on floating bars only, `Segmented Control`, `Slider`, `Switch`, `Chips`, `List`, `Toolbar`, `Sheet`, `Progress`, `HUD`, `Empty State`, `Alert`, `Search Bar`, `Home Indicator`).
  - **10% Fallback (`@samdesain` Swiss Minimalist)**: Custom professional colorist instrumentation not present in standard iOS 26 controls:
    1. **3-Way Color Wheels (Lift / Gamma / Gain)** with 1px monochromatic border (`#27272a` in dark mode, `#e4e4e7` in light mode), center crosshair, and tabular numeric readouts.
    2. **Split-Screen Video Viewport & Technical Telemetry Bar** (`Rec.709 SDR`, `1080x1920`, `60 FPS`, `H.264 High L4.2`, `0.5 LSB Dither`) with crisp 4px to 6px corner radius and matte surface.

## 2. Three Dials (`antislop` Part 3)
- **ENERGY: 1 (Calm / Reference Grade)**: The interface recedes into a neutral chromatic environment so the colorist's eye judges video luminance and chrominance accurately without UI color cast.
- **RHYTHM: 2 (Balanced)**: Distinct structural rhythm separating the full-bleed Metal video canvas, the compact technical telemetry bar, and the tactile parameter deck.
- **MOTION: 1 (Functional Only)**: Zero decorative loops or pulsing dots. Motion is strictly bound to real-time 60fps frame rendering, split-screen wipe dragging, and sheet transitions.

## 3. Color Palette & Typography
- **Core Neutrals (Zinc Darkroom Scale)**:
  - Canvas Background: `#09090b` (Dark) / `#f4f4f5` (Light inspection mode)
  - Elevated Deck Surface: `#121215` (Dark) / `#ffffff` (Light)
  - Control Well & Border: `#18181b` fill with `1px solid #27272a` (Dark) / `1px solid #d4d4d8` (Light)
  - Primary Text: `#fafafa` (Dark, contrast > 15:1) / `#09090b` (Light, contrast > 15:1)
  - Secondary Text: `#a1a1aa` (Dark, contrast >= 5.2:1 on `#09090b`) / `#52525b` (Light, contrast >= 5.4:1 on `#ffffff`)
- **Single Deliberate Accent**:
  - Reference Amber (`#f59e0b` on Dark / `#d97706` on Light) and iOS System Tint (`#007aff`) reserved strictly for active primary export action and active LUT/split selection.
- **Typography**:
  - UI & Navigation: `-apple-system, BlinkMacSystemFont, "SF Pro Text", "Inter", sans-serif`
  - Technical Telemetry & Parameter Readouts: `"SF Mono", ui-monospace, Menlo, monospace` with `font-variant-numeric: tabular-nums` so values never jitter during 60fps scrubbing.

## 4. One-Line Decision Log (`antislop` R-31)
- **Why this color palette?**: Neutral Zinc (`#09090b` to `#27272a`) prevents simultaneous color contrast illusions on the human retina while grading skin tones and shadows.
- **Why dark mode by default (with a working light/dark toggle)?**: Industry color grading suites require dark surrounds to judge shadow roll-off near black, while the theme toggle supports outdoor mobile inspection (R-21, R-34).
- **Why this layout?**: Adaptive hierarchy (`Bottom Sheet Deck` on iPhone, `3-Column Split View` on iPad, `Pro NLE Inspector` on Mac) prioritizes maximum uncropped video viewport area on every screen size.
- **Why this typography?**: System SF Pro provides native Apple legibility, while tabular SF Mono prevents horizontal layout shift when dragging continuous EV/Kelvin sliders.
- **Why this spacing & border radius?**: Native iOS 26 containers use standard sheet/bar geometry (90%), while fallback technical instruments use 1px borders and 6px radius (10% `@samdesain`) to distinguish data readouts from navigation bars.
- **Why Liquid Glass on at most 1-2 floating bars?**: Restricting `ios-glass` to the floating transport toolbar and sheet header keeps the video canvas and parameter rows crystal clear and adheres to the R-10 dose cap.
- **Why these icons?**: Native iOS 26 icons (`ios-icon--play`, `ios-icon--sun`, `ios-icon--share`, `ios-icon--folder`, `ios-icon--checkmark`) map 1:1 to media transport and file operations without decorative AI symbols (R-04).

