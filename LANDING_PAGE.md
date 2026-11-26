# Fluent Landing Page Design Specification

> **Document Type:** Design System & Content Blueprint
> **Version:** 1.0
> **Last Updated:** February 2026

A comprehensive specification for a single-page marketing landing page for Fluent — the free, open-source, local AI voice dictation app for macOS.

**Key Positioning:** Free alternative to Wispr Flow ($12-15/month) with 100% local processing and zero cloud dependencies.

---

## Table of Contents

1. [Design System](#design-system)
2. [Page Sections](#page-sections)
3. [Responsive Considerations](#responsive-considerations)
4. [Implementation Notes](#implementation-notes)

---

## Design System

### Color Palette

| Token | Hex Value | RGB | Usage |
|-------|-----------|-----|-------|
| `--color-primary` | `#4270FB` | 66, 112, 251 | CTAs, links, brand accents |
| `--color-primary-hover` | `#3560E0` | 53, 96, 224 | Button hover states |
| `--color-primary-muted` | `#4270FB1A` | — | Primary with 10% opacity backgrounds |
| `--color-background` | `#0A0A0F` | 10, 10, 15 | Page background |
| `--color-surface` | `#15151F` | 21, 21, 31 | Card backgrounds, sections |
| `--color-surface-light` | `#1E1E2A` | 30, 30, 42 | Elevated cards, hover states |
| `--color-surface-border` | `#2A2A3A` | 42, 42, 58 | Subtle borders |
| `--color-text-primary` | `#FFFFFF` | 255, 255, 255 | Headlines, primary body text |
| `--color-text-secondary` | `#A0A0B0` | 160, 160, 176 | Secondary/muted text |
| `--color-text-tertiary` | `#6B6B7B` | 107, 107, 123 | Placeholder, disabled text |
| `--color-success` | `#22C55E` | 34, 197, 94 | Checkmarks, positive indicators |
| `--color-success-muted` | `#22C55E1A` | — | Success badge backgrounds |
| `--color-error` | `#EF4444` | 239, 68, 68 | Competitor negatives, warnings |
| `--color-error-muted` | `#EF44441A` | — | Error badge backgrounds |
| `--color-accent-purple` | `#7C3AED` | 124, 58, 237 | Gradient end, secondary accent |

### Gradients

```css
/* Hero gradient accent line */
--gradient-primary: linear-gradient(90deg, #4270FB 0%, #7C3AED 100%);

/* Glow effect for CTAs */
--gradient-glow: radial-gradient(ellipse at center, #4270FB33 0%, transparent 70%);

/* Card hover highlight */
--gradient-card-shine: linear-gradient(135deg, #FFFFFF08 0%, transparent 50%);

/* Background mesh (subtle) */
--gradient-mesh: radial-gradient(at 20% 30%, #4270FB0D 0%, transparent 50%),
                 radial-gradient(at 80% 70%, #7C3AED0D 0%, transparent 50%);
```

### Typography

| Element | Font Family | Size | Weight | Line Height | Letter Spacing |
|---------|-------------|------|--------|-------------|----------------|
| Display | SF Pro Display | 56px | 700 (Bold) | 1.1 | -0.02em |
| H1 | SF Pro Display | 48px | 700 (Bold) | 1.15 | -0.02em |
| H2 | SF Pro Display | 36px | 600 (Semibold) | 1.2 | -0.01em |
| H3 | SF Pro Display | 24px | 600 (Semibold) | 1.3 | 0 |
| H4 | SF Pro Display | 20px | 600 (Semibold) | 1.4 | 0 |
| Body Large | SF Pro Text | 18px | 400 (Regular) | 1.6 | 0 |
| Body | SF Pro Text | 16px | 400 (Regular) | 1.6 | 0 |
| Body Small | SF Pro Text | 14px | 400 (Regular) | 1.5 | 0 |
| Caption | SF Pro Text | 12px | 500 (Medium) | 1.4 | 0.02em |
| Badge | SF Pro Rounded | 12px | 500 (Medium) | 1 | 0.04em |
| Button | SF Pro Text | 16px | 500 (Medium) | 1 | 0.01em |

**Fallback Stack:** `system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif`

### Spacing System (4pt Grid)

| Token | Value | Common Usage |
|-------|-------|--------------|
| `--space-1` | 4px | Tight inline spacing |
| `--space-2` | 8px | Element gaps, icon margins |
| `--space-3` | 12px | Small component padding |
| `--space-4` | 16px | Card internal padding |
| `--space-5` | 20px | Section internal gaps |
| `--space-6` | 24px | Card padding, component gaps |
| `--space-8` | 32px | Grid gaps, major element spacing |
| `--space-10` | 40px | Section title margins |
| `--space-12` | 48px | Between section elements |
| `--space-16` | 64px | Section vertical padding |
| `--space-20` | 80px | Major section padding |
| `--space-24` | 96px | Hero section padding |

### Border Radius

| Token | Value | Usage |
|-------|-------|-------|
| `--radius-sm` | 6px | Small buttons, badges |
| `--radius-md` | 8px | Input fields, small cards |
| `--radius-lg` | 12px | Buttons, medium cards |
| `--radius-xl` | 16px | Large cards, sections |
| `--radius-2xl` | 24px | Hero elements, featured cards |
| `--radius-full` | 999px | Pills, circular badges |

### Shadows & Elevation

```css
/* Card shadow */
--shadow-card: 0 4px 24px rgba(0, 0, 0, 0.3);

/* Elevated card */
--shadow-elevated: 0 8px 32px rgba(0, 0, 0, 0.4);

/* Button shadow */
--shadow-button: 0 4px 12px rgba(66, 112, 251, 0.3);

/* Glow effect for primary elements */
--shadow-glow: 0 0 40px rgba(66, 112, 251, 0.2);
```

### Animation & Transitions

| Type | Duration | Easing | Usage |
|------|----------|--------|-------|
| Fast | 150ms | ease-out | Hover states, micro-interactions |
| Normal | 200ms | ease-in-out | Button clicks, tooltips |
| Slow | 300ms | ease-in-out | Card reveals, modals |
| Spring | 400ms | cubic-bezier(0.34, 1.56, 0.64, 1) | Bouncy animations |

---

## Page Sections

### 1. HEADER (Fixed Navigation)

**Behavior:** Fixed to top, blur backdrop on scroll, 64px height

**Layout:**
```
[Logo]                    [Features] [Compare] [Download]   [Download Free →]
```

**Content:**
- **Logo:** "Fluent" wordmark (text-based, white, 24px, semibold)
- **Nav Links:** Features, Compare, Download (smooth scroll anchors)
- **CTA Button:** "Download Free" with arrow icon

**Styles:**
- Background: `transparent` → `#0A0A0FE6` on scroll (with backdrop blur)
- Border bottom on scroll: `1px solid #2A2A3A`
- Z-index: 100
- Transition: background 200ms

---

### 2. HERO SECTION

**Layout:** Centered, single column, max-width 800px

**Content:**

```markdown
# Your Voice. Your Mac. Your Privacy.

Fluent is a free, open-source voice dictation app that runs 100% locally.
No subscriptions. No cloud. No limits.

[■ Download for macOS]  [◇ View on GitHub]

────────────────────────────────

[100% Free] · [Local AI] · [Open Source]

★ 1.2k stars on GitHub
```

**Visual Elements:**
- Animated waveform visualization (optional, below headline)
- Gradient accent line below CTAs
- Trust badges in pill style
- GitHub stars count (dynamic or placeholder)

**Copy Details:**
- **Headline:** "Your Voice. Your Mac. Your Privacy."
- **Subheadline:** "Fluent is a free, open-source voice dictation app that runs 100% locally. No subscriptions. No cloud. No limits."
- **Primary CTA:** "Download for macOS" with download icon + "Free" badge
- **Secondary CTA:** "View on GitHub" with GitHub icon (ghost button style)

**Badge Content:**
| Badge | Icon | Color |
|-------|------|-------|
| 100% Free | Sparkles/Gift | Success green |
| Local AI | CPU/Chip | Primary blue |
| Open Source | Code/Branch | Accent purple |

---

### 3. COMPARISON SECTION (vs Wispr Flow)

**Anchor ID:** `#compare`

**Layout:** Two-column table with visual differentiation

**Headline:** "Why Pay $180/year for Voice Dictation?"

**Subheadline:** "Fluent gives you everything you need — for free."

**Comparison Table:**

| Feature | Fluent | Wispr Flow |
|---------|--------|------------|
| **Price** | Free forever ✓ | $15/month ✗ |
| **Processing** | 100% Local ✓ | Cloud (OpenAI/Meta) ✗ |
| **Privacy** | Voice stays on your Mac ✓ | Voice sent to servers ✗ |
| **Word Limit** | Unlimited ✓ | 2,000/week (free tier) ✗ |
| **Offline Mode** | Works offline ✓ | Requires internet ✗ |
| **Open Source** | MIT License ✓ | Proprietary ✗ |
| **Account Required** | No ✓ | Yes ✗ |

**Visual Styling:**
- Fluent column: Success green checkmarks, subtle green left border
- Wispr column: Error red X marks, subtle red tint
- Row hover: Slight background highlight
- Feature names in bold

**CTA:** "Switch to Fluent — It's Free" (primary button)

---

### 3B. DETAILED PRICING COMPARISON

**Layout:** Full-width table with 4 columns

**Headline:** "Save $180+ Every Year"

**Pricing Table:**

| | Fluent | Wispr Flow Basic | Wispr Flow Pro |
|---|--------|------------------|----------------|
| **Monthly Cost** | **$0** | $0 (limited) | $15/month |
| **Annual Cost** | **$0** | $0 (limited) | $144/year |
| **Word Limit** | Unlimited | 2,000/week | Unlimited |
| **Languages** | 12+ | 100+ | 100+ |
| **Command Mode** | Coming Soon | — | ✓ |
| **Local Processing** | ✓ | ✗ Cloud | ✗ Cloud |
| **Privacy** | ✓ Full | ✗ Data sent to cloud | ✗ Data sent to cloud |
| **Open Source** | ✓ MIT License | ✗ | ✗ |
| **Offline Mode** | ✓ | ✗ | ✗ |
| **Account Required** | ✗ No | ✓ Yes | ✓ Yes |

**Cost Over Time Callout:**

```
┌─────────────────────────────────────────────────┐
│  💰 Cost Comparison Over Time                   │
├─────────────────────────────────────────────────┤
│  1 Year:   Fluent $0  vs  Wispr Pro $144        │
│  2 Years:  Fluent $0  vs  Wispr Pro $288        │
│  3 Years:  Fluent $0  vs  Wispr Pro $432        │
└─────────────────────────────────────────────────┘
```

**Bottom Line Quote:**
> "Why rent when you can own? Fluent is free forever."

---

### 4. FEATURES SECTION

**Anchor ID:** `#features`

**Layout:** 3-column grid (2 columns on tablet, 1 on mobile)

**Headline:** "Everything You Need. Nothing You Don't."

**Subheadline:** "Powerful features, zero complexity."

**Feature Cards:**

#### Card 1: Local AI Transcription
- **Icon:** Brain/CPU chip
- **Title:** Local AI Transcription
- **Description:** Powered by WhisperKit with OpenAI Whisper. All processing happens on your Mac — your voice never leaves your device.

#### Card 2: Smart Text Formatting
- **Icon:** Sparkles/Magic wand
- **Title:** Smart Text Formatting
- **Description:** Automatic punctuation and capitalization. Spoken lists become formatted bullet points. Polish without extra effort.

#### Card 3: Global Hotkeys
- **Icon:** Keyboard
- **Title:** Global Hotkeys
- **Description:** Press Fn or Option+Space from any app to start recording. Fully customizable shortcuts to fit your workflow.

#### Card 4: Instant Auto-Paste
- **Icon:** Clipboard/Paste
- **Title:** Instant Auto-Paste
- **Description:** Transcribed text automatically pastes where your cursor is. One keystroke from thought to text.

#### Card 5: 12+ Languages
- **Icon:** Globe
- **Title:** 12+ Languages
- **Description:** English, Spanish, French, German, Arabic, Chinese, Japanese, Korean, and more. Auto-detection available.

#### Card 6: Recording History
- **Icon:** Clock/History
- **Title:** Recording History
- **Description:** Searchable history of all transcriptions. Organized by date with original and formatted text comparison.

**Card Styling:**
- Background: `--color-surface`
- Border: `1px solid --color-surface-border`
- Padding: 24px
- Border radius: 16px
- Hover: Subtle lift with `--shadow-elevated`
- Icon: 48px, `--color-primary` with muted background circle

---

### 5. HOW IT WORKS

**Layout:** Three-step horizontal flow (vertical on mobile)

**Headline:** "3 Steps to Faster Writing"

**Subheadline:** "From voice to text in seconds."

**Steps:**

```
    ①                    ②                    ③
   Press               Speak                Done

Hold Fn key        Talk naturally       Text appears
or Option+Space    into your mic        wherever you're
                                        typing
```

#### Step 1: Press
- **Number:** 1 (large, accent color)
- **Title:** Press
- **Description:** Hold the Fn key or Option+Space to start recording.
- **Visual:** Keyboard icon with highlighted key

#### Step 2: Speak
- **Number:** 2 (large, accent color)
- **Title:** Speak
- **Description:** Talk naturally into your microphone. Speak as long as you need.
- **Visual:** Microphone icon with sound waves

#### Step 3: Done
- **Number:** 3 (large, accent color)
- **Title:** Done
- **Description:** Release the key. Your transcribed text appears instantly where you're typing.
- **Visual:** Text cursor with typed text

**Visual:** Connecting line/arrows between steps (animated on scroll)

---

### 5B. DEMO VIDEO SECTION

**Layout:** Centered, max-width 960px

**Headline:** "See Fluent in Action"

**Content:**
- 16:9 aspect ratio video container
- Dark background with rounded corners (16px)
- Play button overlay (centered, large, translucent)
- Subtle glow effect on hover

**Video Placeholder Design:**
```
┌─────────────────────────────────────────────────────────┐
│                                                         │
│                                                         │
│                      ▶ Play                             │
│                                                         │
│                                                         │
│         [Screenshot of Fluent recording overlay]        │
│                                                         │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

**Caption:** "Watch how Fluent transforms your voice into text — instantly and privately."

**Video Concepts (for future recording):**
1. **Quick Demo (30s):** Hotkey → speak → auto-paste workflow
2. **Features Tour (2min):** Complete walkthrough of main features
3. **Comparison Demo:** Side-by-side vs cloud dictation (speed/privacy)

**Fallback:** If no video available, display animated GIF of the recording overlay with waveform + transcription appearing

---

### 6. PRIVACY SECTION

**Layout:** Two-column (content left, visual right) or single centered

**Headline:** "Your Voice Never Leaves Your Mac"

**Subheadline:** "Complete privacy by design, not by policy."

**Key Points (with checkmarks):**
- ✓ No cloud servers — processing happens on-device
- ✓ No accounts required — start using immediately
- ✓ No tracking or analytics — zero data collection
- ✓ No API keys needed — no external dependencies
- ✓ Works completely offline — after initial model download
- ✓ Open source on GitHub — fully auditable code

**Quote Block:**
> "Unlike cloud dictation apps that send your voice to external servers, Fluent processes everything locally using Apple's Core ML framework. Your voice data never leaves your Mac."

**Visual:** Shield icon or lock illustration with Mac device

---

### 7. TECHNICAL SPECS

**Layout:** Compact table or specs grid

**Headline:** "Built for Performance"

**Subheadline:** "Native macOS app optimized for Apple Silicon."

**Specs Table:**

| Specification | Value |
|---------------|-------|
| **Model Size** | ~630 MB (one-time download) |
| **Startup Time** | Instant (lazy model loading) |
| **Accuracy** | 95%+ with OpenAI Whisper |
| **Languages** | 12+ supported |
| **Platform** | macOS 14+ (Sonoma) |
| **Chip Support** | Apple Silicon (M1/M2/M3/M4) & Intel |
| **Audio Format** | M4A (AAC) at 16-44.1 kHz |
| **Storage** | Local SwiftData database |

**Additional Tech Badges:**
- SwiftUI
- WhisperKit
- Core ML
- MIT License

---

### 8. SOCIAL PROOF / TRUST

**Layout:** Centered, minimal

**Content:**
- GitHub stars badge (dynamic): "★ 1,200+ stars on GitHub"
- "Open source and trusted by developers worldwide"
- Optional: User testimonial cards (can be added later)

**Testimonial Card Template (for future use):**
```
┌─────────────────────────────────────────┐
│  "Fluent replaced my $15/month          │
│   dictation app. Same accuracy,         │
│   complete privacy."                    │
│                                         │
│   — @username, Developer                │
└─────────────────────────────────────────┘
```

---

### 9. FAQ SECTION

**Layout:** Accordion or stacked cards

**Headline:** "Frequently Asked Questions"

**Questions & Answers:**

#### Q1: Is Fluent really free?
Yes, 100% free and open source under the MIT License. No subscriptions, no premium tiers, no hidden costs. Ever.

#### Q2: Does it work offline?
Yes. After the initial model download (~630 MB), Fluent works completely offline. No internet connection required.

#### Q3: Is my voice data private?
Absolutely. Your voice never leaves your Mac. All transcription happens locally using Apple's Core ML. We don't have servers to send data to.

#### Q4: What languages are supported?
Fluent supports 12+ languages including English, Spanish, French, German, Italian, Portuguese, Dutch, Russian, Chinese, Japanese, Korean, and Arabic. Auto-detection is also available.

#### Q5: How accurate is it?
Fluent uses OpenAI's Whisper model via WhisperKit, achieving 95%+ accuracy. Smart formatting adds punctuation and capitalization automatically.

#### Q6: Is it Mac only?
Yes, Fluent is a native macOS app built with SwiftUI. It requires macOS 14 (Sonoma) or later and runs on both Apple Silicon and Intel Macs.

#### Q7: How do I customize the hotkey?
Open Fluent, go to the Shortcuts tab, click on any shortcut, and press your desired key combination. Changes save automatically.

#### Q8: What about Accessibility permissions?
Microphone access is required for recording. Input Monitoring is needed for global hotkeys. Accessibility is optional but enhances paste functionality.

---

### 10. DOWNLOAD / CTA SECTION

**Anchor ID:** `#download`

**Layout:** Centered, prominent

**Headline:** "Ready to Ditch Subscriptions?"

**Subheadline:** "Download Fluent free and start dictating in seconds."

**Primary CTA:**
- Button: "Download for macOS" (large, primary style)
- Icon: Download arrow + Apple logo
- Badge: "Free" in success green

**Secondary CTA:**
- Link: "View source on GitHub" (text link with GitHub icon)

**System Requirements Note:**
```
Requires macOS 14 (Sonoma) or later
Apple Silicon or Intel Mac
```

**Trust Indicators:**
- "No account required"
- "Works offline after setup"
- "MIT License"

---

### 11. FOOTER

**Layout:** Simple, centered or 3-column

**Content:**

**Left/Center:**
- Fluent logo (wordmark)
- Tagline: "Open-source voice dictation for macOS"

**Links:**
- GitHub
- Privacy (link to privacy section or separate page)
- License (MIT)
- Releases

**Bottom:**
- Copyright: "© 2026 Fluent. Open source under MIT License."
- Made with line: "Made with ❤️ for privacy"

---

## Responsive Considerations

### Breakpoints

| Name | Width | Usage |
|------|-------|-------|
| Mobile | < 640px | Single column, stacked layout |
| Tablet | 640px - 1024px | 2 columns, adjusted spacing |
| Desktop | > 1024px | Full layout, 3 columns |
| Wide | > 1280px | Max-width containers |

### Mobile Adaptations

- **Header:** Hamburger menu for navigation
- **Hero:** Reduced font sizes (Display → 36px)
- **Comparison Table:** Horizontal scroll or stacked cards
- **Features Grid:** Single column cards
- **How It Works:** Vertical steps
- **Footer:** Stacked, centered

### Container Max-Widths

- Content max-width: 1200px
- Narrow content (text-heavy): 800px
- Wide tables: 1000px

---

## Implementation Notes

### Fonts

Use system fonts for optimal performance on macOS:
```css
font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "SF Pro Text", system-ui, sans-serif;
```

For rounded badges/pills:
```css
font-family: "SF Pro Rounded", -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
```

### Icons

Recommended: SF Symbols or Lucide Icons
- Keep stroke width consistent (1.5-2px)
- Use `currentColor` for easy theming

### Performance

- Lazy load video/demo section
- Use `loading="lazy"` for images below fold
- Preload critical fonts
- Optimize hero animation for 60fps

### SEO Meta Tags

```html
<title>Fluent — Free Voice Dictation for macOS</title>
<meta name="description" content="Fluent is a free, open-source voice dictation app for macOS. 100% local AI processing, no cloud, no subscriptions. Your voice never leaves your Mac.">
<meta property="og:title" content="Fluent — Free Voice Dictation for macOS">
<meta property="og:description" content="Free, open-source voice dictation with 100% local AI. No cloud, no subscriptions.">
<meta property="og:type" content="website">
```

### Accessibility

- Color contrast ratios meet WCAG AA (4.5:1 for body text)
- Focus states on all interactive elements
- Semantic HTML structure
- Skip navigation link
- Alt text for all images
- Reduced motion media query support

---

## Verification Checklist

- [x] All sections complete with content
- [x] Design tokens match app aesthetic (adapted for web)
- [x] All copy in English (LTR)
- [x] Competitor comparison data reflects current Wispr Flow pricing ($15/month)
- [x] Feature descriptions match actual app capabilities from README
- [x] Language count accurate (12+ languages)
- [x] System requirements accurate (macOS 14+, Apple Silicon & Intel)
- [x] MIT License correctly stated
- [x] Privacy claims match actual app behavior (100% local)

---

## Future Enhancements

1. **Video Content:** Record demo videos for the video section
2. **Testimonials:** Collect user quotes for social proof section
3. **Analytics:** Consider privacy-respecting analytics (Plausible, Fathom)
4. **Blog/Updates:** Optional blog section for release notes
5. **Localization:** Translate landing page for supported languages
6. **Interactive Demo:** Web-based demo showing transcription (simulated)

---

*This document serves as the complete design specification for the Fluent landing page. It is not the implementation code but rather a comprehensive blueprint for developers and designers to build from.*
