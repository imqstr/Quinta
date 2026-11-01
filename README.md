<div align="center">

<img src="branding/quinta-icon.png" width="128" alt="Quinta icon">

# Quinta

**Run the macOS Roblox client on Linux.** 🐧🎮

A fast, native-feeling launcher built on [Darling](https://www.darlinghq.org/) / CiderDarling,
with a Mac-style desktop app written in Rust and TypeScript.

[![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-0a84ff)](LICENSE)
![Platform: Linux](https://img.shields.io/badge/platform-Linux-5e5ce6)
![Built with Tauri](https://img.shields.io/badge/built%20with-Tauri%202-ff6a3d)

</div>

---

## ✨ Features

| | |
|---|---|
| 🚀 **One-click play** | Downloads, updates and launches the official macOS Roblox client. |
| 🖥️ **Vulkan & GPU selection** | Pick the renderer and graphics card; NVIDIA PRIME and Wayland are handled for you. |
| ⚡ **High refresh rates** | Detects your monitor's refresh rate; FPS caps up to 240+ stick. |
| 🌐 **DNS over HTTPS** | Optional encrypted DNS for the game's connections. |
| 🧩 **FastFlags editor** | Edit client flags from settings, searchable like everything else. |
| 🛠️ **Roblox Studio (experimental)** | The macOS Studio build now starts; see [Studio](#-roblox-studio-experimental). |

## 📦 Requirements

- 🐧 Linux (x86_64) with Wayland or X11
- 🍎 [CiderDarling](docs/DARLING_RUNTIMES.md) installed
- 🦀 Rust (stable) and 🟢 Node.js 18+ to build the app
- 🎮 A GPU with Vulkan or OpenGL drivers

See the [upstream setup documentation](docs/UPSTREAM_README.md) for the full dependency list.

## 🚀 Getting started

```sh
git clone https://github.com/imqstr/Quinta.git
cd Quinta
bash scripts/build-native.sh          # compatibility shim for the game

cd desktop
npm install && npm run build          # interface
cd src-tauri
cargo build --release --features tauri/custom-protocol
```

Run it from the repository root:

```sh
QUINTA_ROOT=$PWD desktop/src-tauri/target/release/quinta
```

Then choose a runtime in **Settings → Advanced** and press **Play**. ▶️

> 💡 `--launch` starts the game right away and `--studio` starts Studio.

## ⚙️ Where things live

| Path | What |
|---|---|
| `~/.config/quinta/` | ⚙️ Settings, runtime selection, FastFlags |
| `~/.cache/quinta/` | 📥 Downloads and generated driver files |
| `logs/` | 📜 Launch logs, also viewable in the app |

Quinta uses its own app ID and folders. It doesn't take over `roblox://` links.
A Darling prefix shared with another launcher must not run both at once. ⚠️

## 🛠️ Roblox Studio (experimental)

The official Intel macOS Studio build now **starts and keeps running** under
CiderDarling. It isn't usable as an editor yet:

- 🔤 Darling's CoreText is mostly stubs, so Studio has no working fonts yet.
- 🧪 Some AppKit/Foundation methods are still missing and are being filled in.

The Studio compatibility layer is in
[`experimental/macos-studio`](experimental/macos-studio/README.md). Build it with
`bash experimental/macos-studio/build.sh`, then start Studio from Quinta or with
`--studio`. Close the game before testing Studio in the same prefix.

## 🐞 Reporting problems

Open an [issue](https://github.com/imqstr/Quinta/issues) with the launch log from
**Logs** in the app. Logs stay on your computer until you share them. 🔒

## 📄 License & credits

GPL-3.0; see [LICENSE](LICENSE). Quinta is a fork of
[Quadra](https://github.com/QuadraHQ/Quadra) and builds on its contributors' work,
plus Darling, CiderDarling and the native compatibility projects. Upstream
copyright notices and attribution are kept.

Quinta is not affiliated with Roblox Corporation.
