---
name: frontend-design-pro
description: Create distinctive, production-grade frontend interfaces with
  exceptional design quality. Triggers on any UI/frontend task — landing pages,
  dashboards, components, web apps, posters. Eliminates generic AI aesthetics
  and produces memorable, cohesive designs.
---

# Frontend Design Pro

You produce generic "AI slop" without guidance. This skill fixes that.

## Pre-Code Design Brief (mandatory, 3-5 sentences)

Before writing ANY code, write a brief:
1. **Intent**: What does this solve? For whom?
2. **Aesthetic direction**: Name ONE specific vibe (not "modern" or "clean" —
   those are non-answers). Examples: brutalist newspaper, luxury swiss watchmaker,
   90s rave flyer, Japanese garden zen, Soviet constructivism, Miami art deco,
   Dieter Rams industrial, Memphis Group playful, dark academia editorial.
3. **Hero detail**: ONE thing that will make this unforgettable — a specific
   animation, an unusual layout, a texture, an interaction.
4. **Font pairing**: Declare your exact fonts before coding. NEVER: Inter, Roboto,
   Arial, Open Sans, Lato, system fonts, Space Grotesk.

## Typography

Pick fonts with character. Load from Google Fonts.

Distinctive pairings to draw from (never repeat across projects):
- Editorial: Playfair Display + Source Serif Pro
- Technical: IBM Plex Mono + IBM Plex Sans
- Luxe: Cormorant Garamond + Montserrat
- Expressive: Bricolage Grotesque + Newsreader
- Geometric: Outfit + DM Sans
- Retro: Darker Grotesque + Libre Baskerville
- Brutalist: Archivo Black + Space Mono
- Organic: Fraunces + Nunito Sans
- Art Deco: Poiret One + Raleway
- Playful: Fredoka + Quicksand

Weight extremes: 100-200 vs 700-900. Size jumps: 3x minimum.
One display font for impact, one body font for reading.

## Color

CSS variables. Always. Name them semantically: --color-surface, --color-accent,
--color-text-primary, not --blue-500.

Strategy: ONE dominant color, ONE sharp accent, rest neutral.
Bold palettes >> safe pastels. Vary between light/dark across projects.

Draw inspiration from: IDE themes (Dracula, Nord, Catppuccin, Gruvbox),
film color grading, album artwork, architectural photography, nature.

NEVER: purple-on-white gradients, teal-and-coral combos, or any palette
that screams "AI generated this."

## Motion

Less is more, but that "less" must be exquisite.

Priority: ONE orchestrated page load with staggered reveals (animation-delay:
0.1s increments). This single effect > 20 random micro-interactions.

CSS-first: transforms, transitions, @keyframes.
React: Framer Motion / Motion library when available.
Meaningful triggers: scroll-based reveals, hover state surprises,
loading→content transitions.

Never animate for decoration. Every animation should communicate.

## Layout & Space

Break the grid. At least ONE element should challenge the expected layout:
- Overlapping elements
- Asymmetric columns
- Full-bleed sections next to contained ones
- Diagonal flows or rotated elements
- Generous negative space that breathes

NEVER: everything centered on white, symmetric card grids with uniform
rounded corners, predictable hero→features→CTA→footer.

## Backgrounds & Texture

Create depth and atmosphere:
- Gradient meshes, radial gradients with multiple stops
- Subtle noise/grain overlays (CSS filter or SVG)
- Geometric patterns as section dividers
- Layered transparencies
- Dramatic box-shadows for elevation
- Contextual effects: code rain for dev tools, paper texture for
  editorial, glass morphism for dashboards

## Implementation

- Production-grade: semantic HTML, ARIA roles, focus states, contrast ratios
- CSS custom properties for theming
- Mobile-first responsive
- Match complexity to vision: maximalist → elaborate code; minimalist →
  restraint and precision
- Working, functional code — not mockups

## Anti-Convergence Rule

You WILL try to converge on familiar choices even with these instructions.
After writing your design brief, check: have you used this font/color/layout
in a recent generation? If yes, pick something else. Surprise yourself.
