# Assets

The packaged app references four images that do not exist yet:

```text
StoreLogo.png          50x50   (Package.appxmanifest > Properties > Logo)
Square150x150Logo.png 150x150
Square44x44Logo.png    44x44
Wide310x150Logo.png   310x150
```

They are intentionally missing: placeholder art committed as a "logo" has a habit
of surviving to release. Source artwork lives in `/assets/branding`; the icons are
generated from it at stage 6, when packaging is real.

Until then, `msbuild` will fail with an asset error — that is the honest state,
not a bug to work around. If you need to build the shell before the art exists,
generate neutral grey squares locally and do not commit them.
