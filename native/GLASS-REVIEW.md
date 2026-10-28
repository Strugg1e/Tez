# Glass material revision, second pass

## Scope

The preview only uses fixture data. No proxy service, network settings, or production app was changed.

## Cause and changes

The live AppKit hierarchy showed NavigationSplitView already wrapping the sidebar
in NSGlassEffectView. Our empty glass background was nested inside it, and another
material covered the entire root. The custom overlays added flat color without
making foreground content part of the system glass content hierarchy.

- Removed the custom sidebar glass, root material, tint overlays, and painted window outline.
- Let NavigationSplitView own sidebar material and vibrancy.
- Use headerView and contentBackground materials for route information.
- Use glassProminent only for the primary action on macOS 26, with borderedProminent fallback.
- Retain native toolbar background; forcing titlebar transparency caused a white strip in dark mode.
- Keep the table opaque, including its column header.
- Add an opaque content fallback for increased contrast, in addition to reduced transparency.
- Use a short non-bouncing spring for route feedback and symbol replacement for favorites; both respect reduced motion.

## Verification

`bash test-materials.sh` first failed with `Found 1 glass backgrounds nested inside system glass`.
After the fix it passed four checks: no nested glass, two semantic content materials,
reduced-transparency fallback, and increased-contrast fallback. The initial XCTest
attempt could not run because the local Command Line Tools lack XCTest; the final
standalone check compiles the actual views and does not show a window.

`bash build-preview.sh` passed compilation and signing. Native UI checks covered
light/dark appearance, preview accessibility switches, favorite toggling, and route
activation with both normal and reduced motion. No frame-rate measurement was made.

Evidence: output.noindex/glass-semantic-light.png, glass-semantic-dark.png,
glass-reduced-dark.png, and glass-contrast-light.png. The dark screenshot visibly
shows background variation in the sidebar; the reduced-transparency screenshot
shows its opaque fallback. Light mode remains more restrained than the approved
static coastal mock. Matched-backdrop comparison is unverified: the automation's
Window menu returned stale elements when attempting to move between displays.
No claim of pixel-for-pixel reference parity is made.

Temporary hierarchy logging was removed. No system wallpaper or accessibility
settings were changed. Only the separate native preview was rebuilt and launched.
