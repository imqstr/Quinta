# Quinta

Quinta is [imqstr](https://github.com/imqstr)'s experimental launcher for running the
macOS Roblox client on Linux through Darling/CiderDarling.

## Development checkout

On a machine with Quinta's dependencies and CiderDarling already installed:

```sh
git clone https://github.com/imqstr/Quinta.git
cd Quinta
bash launcher/install-quinta.sh
quinta
```

Quinta uses its own app ID and `~/.config/quinta` / `~/.cache/quinta`
folders. It does not automatically move Quinta's settings or take over Roblox
protocol links. Choose a runtime in Quinta's settings, or copy a known working
`runtime.json` into `~/.config/quinta`. A selected Darling prefix is still
shared with any other launcher selecting that prefix; do not run both at once.
The source checkout builds its own shim and downloads its own Roblox client.

The inherited root installer and packaging recipes are still upstream-oriented;
use `launcher/install-quinta.sh` for this development fork. Runtime ABI names,
the Python `quadra` package, and existing icons remain from upstream.
See [upstream setup documentation](docs/UPSTREAM_README.md) for dependencies.

## Initial changes

- Separate Quinta launcher, application ID, settings, cache, and shortcuts.
- Update checks and checkout updates point to `imqstr/Quinta`.
- Verified HeightmapDebugPS shader parser repair for Roblox 0.745.0.7451137.
- Gradient shader capture for investigating invisible UIGradient elements.

## Missing UI gradients

This is under investigation; the fork does **not** claim a fix yet.
Capture the installed client’s gradient shaders without launching Roblox:

```sh
quinta --dump-gradient-shaders /tmp/quinta-gradients
```

The destination must be new. The capture includes source hashes and pack hash;
it stays on your computer. To check the actual GLSL on your host driver:

```sh
clang -O2 tests/shader_driver_test.c shader_compat.c -lEGL -lGL -o /tmp/quinta-shader-test
EGL_PLATFORM=x11 /tmp/quinta-shader-test /tmp/quinta-gradients/*.frag
```

Successful compilation alone does not prove gradient rendering: atlas uploads,
sampler bindings, constants, blending and rendering through Darling still need
verification. The HeightmapDebugPS repair is a separate confirmed parser issue.

## macOS Studio experiment

An official Intel macOS Studio build was tested through CiderDarling.
It reaches Qt window creation after filling two missing API symbols, then
segfaults. It is not a working editor yet. Run the experiment with:

```sh
quinta --macos-studio --bundle /path/to/RobloxStudio.app
```

This builds the small Studio shim and writes a local startup log in
`experimental/macos-studio/launch.log`. Close Player before testing Studio
in the same prefix. [Startup findings](experimental/macos-studio/README.md)
describe the current blocker.

## License and credits

GPL-3.0; see [LICENSE](LICENSE). Quinta builds on the [upstream project](https://github.com/QuadraHQ/Quadra) and its contributors;
upstream code, copyright notices and attribution are retained.
