# macOS Studio startup experiment

Tested with the official Intel MacStudio 0.745.0.7451137 archive,
`version-a7baca1cb08a4943`, obtained from Roblox's deployment API and CDN:

- `https://clientsettingscdn.roblox.com/v2/client-version/MacStudio`
- `https://setup.rbxcdn.com/mac/version-a7baca1cb08a4943-RobloxStudioApp.zip`

The archive and extracted app are local artifacts, excluded from git.

## Findings

1. Bare Studio fails in dyld: missing `kCVPixelBufferCGBitmapContextCompatibilityKey`.
2. Quinta's inherited Player shim supplies that constant and other existing APIs.
3. Studio next requires `WKWebsiteDataTypeCookies`. The separate Studio shim
   defines the public WebKit data-store identifier.
4. Qt's `libqcocoa.dylib` requires `CGDisplayIsOnline`. The separate shim
   implements this using Darling's existing `CGGetOnlineDisplayList`.
5. Studio then creates two `NSWindow` objects and receives SIGSEGV before
   an editor or login UI becomes usable. Reproduced with both the installed
   Quinta shim and the freshly built Quinta shim, using the X11 backend.

The runtime tested was Quinta's pinned CiderDarling revision
`b0fcb0700dc1322cf8a840e69ccd469fecd0f0e7`. No conclusion about the exact
crashing Qt/AppKit method has been established. Diagnostic register logs and
core files remain local; they are not published with the source.

## Reproduce

After extracting the Intel Studio app and building the main Quinta shim:

```sh
quinta --macos-studio --bundle /path/to/RobloxStudio.app
```

The launcher rejects a test while a Player process is running in its selected
prefix. Studio's dependencies and graphics initialization require further
compatibility work; these two API additions are not a working Studio port.
