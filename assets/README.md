# Branding assets

Source artwork lives here, checked in as editable files, not as exports:

```text
branding/     logo source (SVG / Affinity / Figma export), colour definitions
icons/        generated .icns (macOS) and .png sizes (Windows MSIX)
screenshots/  user-guide images, captured from a clean install
```

Rules:

- `icons/` is **generated**, never hand-edited. The generator lands with stage 6;
  until then this directory stays empty on purpose — a committed placeholder icon
  has a way of surviving into a release.
- Colours used in UI code must come from the values documented here, not from
  hard-coded hex literals scattered through XAML and SwiftUI.
- Screenshots must not show real repository URLs, user names, or commit messages
  from a private repository.
