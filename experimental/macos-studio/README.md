# 🛠️ Roblox Studio on Linux (experimental)

Quinta runs the official **Intel macOS build of Roblox Studio** through
CiderDarling, with a small compatibility library, `libStudioCompat.dylib`.

## 📍 Status

| | |
|---|---|
| ✅ Starts and keeps running | Gets through Qt's startup and creates its windows |
| 🔤 No text yet | Darling's CoreText is mostly stubs, so no fonts load |
| 🧩 Some features fail | A few AppKit/Foundation methods are still missing |

Tested with Studio `0.745.0.7451137` on CiderDarling
`b0fcb0700dc1322cf8a840e69ccd469fecd0f0e7`.

## ▶️ Try it

```sh
bash experimental/macos-studio/build.sh
quinta --studio
```

Or press **Studio** in the app. Close the game first: both use the same
Darling prefix.

## 🔧 What the compatibility library fixes

| Problem | Fix |
|---|---|
| Qt and Darling's AppKit both define `-platformWindow`, so AppKit got Qt's C++ object and crashed | Each caller gets its own version: libqcocoa gets Qt's, everyone else gets AppKit's |
| Darling's CoreText returns `NULL` fonts that Qt retains and releases | NULL-safe `CFRetain`/`CFRelease` and fallback UI fonts, for libqcocoa only |
| About 30 CoreGraphics, CoreText, AppKit and CoreFoundation functions Studio imports are missing | Added, each behaving like macOS when the resource is unavailable |
| Darling's `KERN_PROCARGS` sysctl overruns its buffer | Reports the query as unsupported |

The game's shim also creates Wayland windows at 1×1 when Qt asks for 0×0
([`native/wayland_appkit.m`](../../native/wayland_appkit.m)).

## 🧭 Next steps

1. Missing `-[NSURLComponents setPath:]` and other methods as they come up
2. A FreeType-backed CoreText, so Studio can draw text
3. Sign-in, the start page, then the editor viewport

## 🐞 Debugging

Crash reports with symbol names:

```sh
QUINTA_GUEST_QUINTA_DIAGNOSTIC_SIGNALS=1 QUINTA_TRACE_CRASH_SYMBOLS=1 quinta --studio
```

Logs are written to `logs/` and shown in the app under **Logs**. The Studio app
and its logs stay on your computer and are excluded from git.
