# Design System Specification: The Architectural Monolith

## 1. Overview & Creative North Star
**Creative North Star: "The Silent Sentinel"**

This design system rejects the cluttered, "noisy" aesthetic of typical enterprise dashboards in favor of an architectural, editorial approach. We treat data as a high-value asset, housed within a space that feels intentional, stable, and profoundly calm. 

To move beyond the "standard template" look, we utilize **Tonal Layering** and **Asymmetric Balance**. By stripping away traditional borders and grid lines, we allow the content to define the structure. The interface should feel like a custom-engineered console—precise, high-density, yet breathable—evoking the quiet confidence of a secure, well-managed data center.

---

## 2. Colors & Surface Philosophy
Our palette is rooted in a sophisticated "Ink and Paper" logic. We use deep sapphire-tinted charcoals for authoritative text and primary actions, set against a pristine, clinical background.

### The "No-Line" Rule
**Traditional 1px borders are strictly prohibited for sectioning.** 
Structure is defined through background shifts. When a new content area is required, move from `surface` to `surface-container-low` or `surface-container-high`. This creates a seamless "molded" look rather than a fragmented "boxed" look.

### Surface Hierarchy & Nesting
Treat the UI as a series of physical layers. 
*   **Base Level:** `surface` (#faf8ff) – The foundation.
*   **Secondary Level:** `surface-container-low` (#f2f3ff) – Used for sidebars or secondary navigation.
*   **Component Level:** `surface-container-lowest` (#ffffff) – Used for primary cards or data tables to make them "pop" against the background.
*   **Active/Elevated Level:** `surface-container-highest` (#d9e2ff) – Reserved for modal overlays or active state highlights.

### Signature Textures
While we avoid neon aesthetics, we use **Micro-Gradients** for primary CTAs. A subtle linear transition from `primary` (#0053db) to `primary_dim` (#0048c1) adds a "machined" feel that flat color cannot achieve, suggesting a tactile, premium button surface.

---

## 3. Typography
We utilize a dual-font strategy to balance character with utility.

*   **Display & Headlines:** **Manrope.** Its geometric yet open nature provides an editorial, modern feel. Use `display-lg` and `headline-md` sparingly to anchor page headers with authority.
*   **Functional UI & Data:** **Inter.** Chosen for its exceptional legibility at small sizes. All labels, table data, and helper text use Inter in **sentence case** to maintain a calm, human tone.

**Hierarchy Rule:** Use weight over size. A `label-md` in Bold is often more effective than a `title-sm` in Regular. This maintains high data density without overwhelming the user’s visual field.

---

## 4. Elevation & Depth
Depth in this system is achieved through light and shadow, not lines.

*   **The Layering Principle:** Place a `surface-container-lowest` card on a `surface-container-low` background. The subtle shift in hex value creates an edge that the eye perceives as a physical step, eliminating the need for a border.
*   **Ambient Shadows:** For floating elements (Modals/Popovers), use a "Deep Diffusion" shadow:
    *   `Y: 16px, Blur: 32px, Color: on_surface @ 6% opacity`.
    *   This mimics natural ambient occlusion, making elements feel like they are hovering on a cushion of air.
*   **The "Ghost Border" Fallback:** If high-contrast environments require containment, use `outline-variant` (#98b1f2) at **15% opacity**. It should be felt, not seen.

---

## 5. Components

### KPI Cards & Data Tiles
*   **Layout:** Vertical stacking. `label-sm` (all caps, 0.05em tracking) at the top, followed by `display-sm` for the value.
*   **Separator:** No lines. Use a 1.5rem (`spacing-6`) vertical gap.
*   **Background:** Always `surface-container-lowest` to ensure maximum contrast for data.

### Data Tables
*   **The Stripeless Rule:** No zebra stripes. Use a 1px `surface-container-low` bottom edge only if rows are exceptionally long.
*   **Header:** `label-md` in `on_surface_variant` (#445d99).
*   **Cell Density:** High. Use `spacing-3` for vertical padding to maximize information on screen.

### Status Chips
*   **Visual Style:** Subtle, desaturated backgrounds with high-contrast text.
*   **Healthy:** `tertiary_container` (#69f6b8) background with `on_tertiary_container` (#005a3c) text.
*   **Error:** `error_container` (#fe8983) background with `on_error_container` (#752121) text.
*   **Geometry:** Use `roundedness-full` to contrast against the sharp `md` (0.375rem) corners of cards and inputs.

### Form Controls
*   **Inputs:** `surface-container-lowest` fill with a `ghost-border`.
*   **Focus State:** A 2px `primary` (#0053db) ring with a 4px soft glow (20% opacity).
*   **Helper Text:** Always positioned below the input using `body-sm`, providing immediate operational context.

### Glassmorphic Overlays
For global navigation or floating action bars, use:
*   `Background: surface @ 80% opacity`
*   `Backdrop-blur: 12px`
*   This keeps the user grounded in their current context while providing a premium, translucent aesthetic.

---

## 6. Do’s and Don’ts

### Do
*   **Do** use whitespace as a functional tool. If two elements feel cluttered, increase the spacing token rather than adding a divider.
*   **Do** use `tertiary` (Emerald) for "Healthy" states to reinforce a sense of operational calm.
*   **Do** utilize **Sentence Case** for all UI labels. It is more readable and less aggressive than Title Case.

### Don’t
*   **Don’t** use pure black (#000000). Always use `on_surface` (#113069) for text to maintain the sophisticated sapphire-charcoal tone.
*   **Don’t** use "Drop Shadows" on cards that are resting on the grid. Reserve shadows exclusively for elements that physically "break" the plane (Modals, Tooltips).
*   **Don’t** use neon or high-vibrancy gradients. We are building an enterprise tool, not a consumer gaming app. Keep the "soul" of the design in the typography and spacing.