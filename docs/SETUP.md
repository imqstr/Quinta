# 🛠️ Setting up Quinta

Quinta needs two things: **Darling** (the layer that runs macOS apps on Linux)
and the **Quinta app**. This page walks through both.

## 1. 🍎 Install Darling

Get the code, then run the installer. It sets up Darling and everything it needs:

```bash
git clone https://github.com/imqstr/Quinta.git
cd Quinta
bash install.sh
```

You choose between two runtimes:

| Runtime | What it is |
|---|---|
| **CiderDarling** (recommended) | Our Darling build with threading, CPU detection and OpenGL fixes. Installs to `/opt/ciderdarling/<revision>`. |
| **Regular Darling** | The upstream DarlingHQ build. |

Pick one up front if you like:

```bash
bash install.sh --darling ciderdarling
bash install.sh --darling regular
```

On Arch and on Ubuntu 24.04+ / Mint 22+, CiderDarling installs from a prebuilt,
checksum-verified release in minutes. Elsewhere it compiles from source
(`DARLING_BUILD_JOBS=8` sets the job count). Arch users can also use the AUR
package `ciderdarling-bin`.

Your choice is saved in `~/.config/quinta/runtime.json`.

<details>
<summary>📦 Installing Darling by hand</summary>

**Arch, CachyOS, EndeavourOS, Manjaro**

```bash
paru -S darling-bin
```

**Debian, Ubuntu, Mint:** download `debs_20260608.zip` from
[Darling v0.1.20260608](https://github.com/darlinghq/darling/releases/tag/v0.1.20260608), then:

```bash
unzip debs_*.zip -d darling-debs
sudo apt install ./darling-debs/*/*.deb
```

**Fedora and others:** follow Darling's
[build guide](https://docs.darlinghq.org/build-instructions.html).

</details>

## 2. 🚀 Install the app

You need [Rust](https://rustup.rs) and Node.js 18+. From the same folder:

```bash
bash scripts/install-app.sh
```

Open **Quinta** from your app menu, or run `quinta`. Press **Play** and the
Roblox client downloads on first launch.

To update, `git pull` and run `scripts/install-app.sh` again. To remove the app,
run `scripts/install-app.sh --remove`.

**NixOS:** use the [Nix package and module](../packaging/nix/README.md), or
`nix run .` from a checkout.

## 📁 Where your data lives

| Path | Contents |
|---|---|
| `~/.config/quinta/` | Settings, runtime choice, FastFlags |
| `~/.cache/quinta/` | Downloads, generated driver files, last error |
| `~/.ciderdarling/` or `~/.darling/` | The Darling prefix, including your Roblox sign-in |

## ❓ FAQ

<details>
<summary>🔒 Is my account safe?</summary>

You sign in inside the Roblox client itself. Your session stays on your
computer, inside the Darling prefix. Quinta never sees your password.

**Never share your Darling prefix folder.** It works like a key to your
account. Nobody from Quinta will ever ask for it; anyone who does is trying to
steal your account.

Quinta isn't affiliated with or endorsed by Roblox Corporation, and isn't
responsible for actions taken on your account.
</details>

<details>
<summary>🐞 Something doesn't work</summary>

Open **Logs** in the app and copy the latest launch log. Then open an
[issue](https://github.com/imqstr/Quinta/issues) or ask in the
[Discord](https://discord.gg/jCjHYYNq48).
</details>

<details>
<summary>🔇 No sound</summary>

Install the PulseAudio tools (`pulseaudio-utils` on Debian/Ubuntu,
`pipewire-audio` on Arch), then restart Roblox.
</details>

## 🙌 Credits

Quinta builds on [Quadra](https://github.com/QuadraHQ/Quadra), Cider and
[Mac O' Blox](https://github.com/narezy) by Narezy. Mac O' Blox was released
under the MIT License; that notice is kept in
[LICENSES/MIT-MacOBlox.txt](../LICENSES/MIT-MacOBlox.txt).

Also thanks to [Darling](https://www.darlinghq.org) and
[CiderDarling](https://github.com/QuadraHQ/CiderDarling). Bundled fonts: Inter and
Geist Mono (SIL OFL).

Quinta is licensed under the [GNU GPL v3](../LICENSE). See the
[upstream notices](../LICENSES/upstream/README.md) for project history and attribution.
