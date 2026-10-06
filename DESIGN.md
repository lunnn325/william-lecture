---
name: William Lecture V1
description: A quiet native bilingual reading workspace for university lectures.
colors:
  deep-teal: "light-dark(rgb(0% 39% 42%), rgb(35% 78% 80%))"
  reading-secondary: "light-dark(rgb(40% 42% 44%), rgb(66% 68% 70%))"
  recovery-warning: "light-dark(rgb(55% 23% 0%), rgb(100% 72% 43%))"
typography:
  chinese-title2:
    fontFamily: "-apple-system, BlinkMacSystemFont, system-ui, sans-serif"
    fontWeight: 500
  english-subheadline:
    fontFamily: "-apple-system, BlinkMacSystemFont, system-ui, sans-serif"
  timestamp-caption2:
    fontFamily: "-apple-system, BlinkMacSystemFont, system-ui, sans-serif"
    fontFeature: "tnum"
  headline:
    fontFamily: "-apple-system, BlinkMacSystemFont, system-ui, sans-serif"
  body:
    fontFamily: "-apple-system, BlinkMacSystemFont, system-ui, sans-serif"
  action-subheadline:
    fontFamily: "-apple-system, BlinkMacSystemFont, system-ui, sans-serif"
    fontWeight: 500
  timer-callout:
    fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace"
    fontFeature: "tnum"
spacing:
  reading-gutter: "22pt"
  caption-text-gap: "10pt"
  caption-line-gap: "5pt"
  caption-row-inset: "12pt"
  caption-row-gap: "12pt"
  reading-max-width: "760pt"
  touch-minimum: "44pt"
  active-control-height: "48pt"
  start-control-height: "52pt"
components:
  button-start:
    backgroundColor: "{colors.deep-teal}"
    typography: "{typography.headline}"
    height: "{spacing.start-control-height}"
  button-secondary:
    textColor: "{colors.deep-teal}"
    height: "{spacing.active-control-height}"
  button-stop:
    height: "{spacing.active-control-height}"
  follow-latest:
    backgroundColor: "{colors.deep-teal}"
    typography: "{typography.action-subheadline}"
    height: "{spacing.touch-minimum}"
  caption-row:
    typography: "{typography.chinese-title2}"
  input-native:
    typography: "{typography.body}"
  navigation-selected:
    textColor: "{colors.deep-teal}"
  history-row:
    typography: "{typography.headline}"
---

# Design System: William Lecture V1

## Overview

**Creative North Star: "Operate / Read"**

The interface is a quiet native lecture page. A brief glance should find the Chinese meaning, with the original English still readable above it. San Francisco, the system's Chinese font fallback, open transcript rows, and a constrained reading column carry the visual character.

Apple navigation, lists, forms, sheets, and materials provide the surrounding structure. Deep teal marks interactive state; neutral text carries the lecture. The supplied bilingual reference establishes the reading rhythm, while the current SwiftUI source establishes the tokens. This document records source-extracted tokens from commit `7f00f4607b8e1d16567f151a347b75ab738e04a9`. Twenty native XCUIScreen captures are available in `.impeccable/review`, with provenance in `capture-info.json`. Capture availability does not establish visual approval. Physical viewport stability as Chinese grows, and real translation latency, remain device checks.

**Key Characteristics:**

- Chinese leads; English remains a readable supporting line.
- Open reading rows use space rather than enclosing cards.
- Essential recording controls stay in the safe area.
- Native controls adapt to appearance and Dynamic Type.
- Caption replacement retains stable identity and respects manual review.

## Colors

The palette uses one adaptive teal tint, a readable neutral secondary, and a reserved recovery warning. The frontmatter expresses the exact fractional RGB channels in `App/ReadingColors.swift` as CSS percentage channels; `light-dark()` maps the source's light and dark appearance branches without rounding them to hex.

### Primary

- **Deep Teal** (`deep-teal`): interactive tint for start, pause, mark, follow-latest, selected navigation, and bookmark state. The active recording dot uses the same tint.

### Neutral

- **Reading Secondary** (`reading-secondary`): English captions, timestamps, supporting instructions, native field prompts, metadata, and the inactive recording dot. English is secondary in hierarchy, not faint or decorative.
- **System Background and Label**: native `systemBackground`, `label`, and SwiftUI `.primary` remain semantic platform colors. They are intentionally not frozen into RGB primitives here. Chinese captions use primary text; stop uses primary foreground as its fill and system background as its label color.

**Recovery Warning** (`recovery-warning`) is a semantic exception for actionable faults and error text, not an additional decorative accent. Native destructive actions retain the system's destructive role.

**The Readable Secondary Rule.** Supporting English must remain readable in both appearances; do not reduce its contrast to make Chinese appear more prominent.

The sidecar's eight-step tonal ramps are synthesized panel aids, not additional application colors. Only the frontmatter colors and native semantic roles are implementation tokens.

## Typography

**UI Font:** Apple's system font, with San Francisco and the platform's native Chinese fallback. No custom font is introduced.

Typography tokens identify native SwiftUI roles. Fixed `fontSize` values are deliberately omitted: text must follow Dynamic Type rather than a browser specimen's point size. The sidecar records the corresponding native styles and provides explicitly approximate browser examples.

### Hierarchy

- **Chinese** (`chinese-title2`): `.title2.weight(.medium)`, primary text, with additional line spacing from `caption-line-gap`. Pending Chinese uses reading-secondary until a draft appears.
- **English** (`english-subheadline`): `.subheadline`, reading-secondary; wraps fully above Chinese.
- **Timestamp** (`timestamp-caption2`): `.caption2` with monospaced digits, reading-secondary. The timestamp remains a quiet audio reference below the caption.
- **Headings and Start Action** (`headline`): `.headline` for course identity, record titles, and the start label. Top-level history and settings use system large navigation titles; deep screens and the reading workspace use inline titles.
- **Body** (`body`): `.body` for native form text and explanatory empty-state copy. Native captions and footnotes remain native styles for smaller supporting UI.
- **Follow Latest** (`action-subheadline`): `.subheadline.weight(.medium)` for the return-to-latest action.
- **Recording Timer** (`timer-callout`): `.system(.callout, design: .monospaced)` with monospaced digits.

**The Glance Order Rule.** Maintain the English-above, Chinese-below, timestamp-last reading order while giving Chinese the strongest text hierarchy.

## Layout

The live workspace and bottom control shelf share horizontal reading gutters and a centered maximum reading measure. Use `reading-gutter` at either side and cap the reading content at `reading-max-width`; do not expand lecture lines across the full iPad width. Native safe-area insets contain the compact status strip above and the control shelf below.

Each caption has vertical padding from `caption-row-inset`. The lazy feed has a separate inter-row gap from `caption-row-gap`; these are distinct spaces, not a single claimed row-separation value. Within the row, `caption-text-gap` separates English, Chinese, and timestamp. Text grows vertically without truncating the bilingual content.

Every tappable control has at least the native touch minimum. The active shelf uses the active-control height, and the start action uses the start-control height. `ViewThatFits` changes the active shelf from one horizontal row to pause/stop above mark when labels need more room. This is content-driven adaptation, including accessibility text sizes, rather than a fixed device breakpoint.

System tab navigation exposes recording, records, and settings. The tab bar hides while a lecture is active; the inline course navigation and safe-area controls remain available. Course selection and focused tasks use native sheets. The left-edge navigation gesture remains native.

## Elevation & Depth

The reading surface is flat and uses open space, text hierarchy, and native grouping. There are no custom shadow tokens. The recording shelf uses the system `.bar` material; sheets and navigation retain system depth and transitions. History is a plain native list, while lesson details and settings use native grouped structures. Do not turn transcript rows into floating cards or add hand-built glass surfaces.

## Shapes

Recording actions and follow-latest use SwiftUI's capsule button shape. Its radius is determined by the native control, so no invented numeric radius is exported. Lists, form fields, sheets, and segmented pickers use their system shapes. Transcript rows remain unenclosed; the reading hit area is rectangular without drawing a box.

## Components

### Buttons

Start is a prominent teal capsule. Pause and mark are bordered capsules with native tint treatment; stop is a prominent capsule using semantic primary fill and system-background label color. Follow-latest is a compact prominent capsule at the lower trailing edge, above the control shelf. Preserve the source heights, accessible labels, native pressed/disabled treatment, and the width-driven stacked shelf. SF Symbols accompany actions without depending on icon recognition alone.

### Native Inputs and Forms

Course entry, model entry, secure key entry, note editing, export choices, and settings use native fields, toggles, pickers, and forms. Course, model, and secure-key prompts explicitly use reading-secondary. Focus, keyboard, validation, destructive confirmation, and dismissal follow platform behavior. Notes provide explicit cancel/save actions and guard dismissal when edits are unsaved. Do not style credential or diagnostics controls as a dashboard.

### Navigation and History

Use the native three-section tab bar, navigation stacks, and focused sheets. History uses system search, pull-to-refresh, course/date/duration rows, and native unavailable/search-empty states. Lesson details use grouped sections for metadata, playback, annotations, and transcript. Playback uses a native slider, labelled transport controls, and quiet time labels; recording availability determines disabled states.

### Bilingual Caption Row

Reuse `CaptionTextView` for live reading and saved transcripts. English comes first, Chinese carries the primary reading weight, and the timestamp comes last. A small filled bookmark reports a mark without adding a badge stack. Live rows support marking, note editing, contextual copying, and named accessibility actions. Each row keeps its UUID across local draft and GPT replacement.

A viewport-size change schedules a settled follow check after 350 ms. Re-anchoring to the bottom runs only while follow remains active and the session identity is unchanged. A newer resize cancels the earlier scheduled task; cancellation and current-state checks keep this resize response from restoring suspended review. This timing is a follow behavior, not a translation animation.

**The Stable Reading Rule.** Retain caption UUIDs and omit replacement animations. Suspend follow for manual review, and expose return-to-latest. Check on device how growing Chinese rows affect the viewport; stable identity alone does not guarantee a fixed reading position.

### Status and Empty States

Recording state uses a quiet dot plus a literal state label and timer. The compact translation summary opens diagnostics; an actionable warning or Speech recovery message uses the warning color. Translation provenance does not become a badge on each caption. Empty states explain the next available action and contain no invented lecture content. Diagnostic and error copy should preserve the distinction between recording, Speech, local draft, and final translation.

The schemaVersion 2 sidecar extends these tokens with metadata, motion, and self-contained browser previews. Those previews approximate native components for inspection; they are not SwiftUI code, simulator evidence, or a replacement design system. Production recording, Speech, local translation, GPT revision, store, and export services remain the product baseline.

## Do's and Don'ts

### Do:

- **Do** use native SwiftUI text styles and verify both appearance modes and accessibility Dynamic Type.
- **Do** keep Chinese primary, English readable, and timestamps quiet in the shared caption component.
- **Do** use the shared reading gutters and maximum measure, with recording controls inside safe-area insets.
- **Do** retain stable caption UUIDs and respect suspended follow during manual review; check growing Chinese rows on device.
- **Do** use native navigation, forms, SF Symbols, sheets, and system materials.

### Don't:

- **Don't** introduce transcript cards, waveform dashboards, loud recording effects, or per-caption translation source badges.
- **Don't** animate local-to-final caption replacement or force scrolling while the user reads earlier captions.
- **Don't** freeze Dynamic Type into fixed font sizes or substitute old screenshots for the current adaptive palette.
- **Don't** truncate essential recording labels at accessibility sizes; allow the control shelf to stack.
- **Don't** treat browser sidecar examples or synthesized tonal ramps as production native tokens or visual verification.
