# NixOS

The flake builds Quinta for **x86_64-linux**, including the launcher, shim,
native Wayland helper, Metal bridge and a pinned Darling runtime.
**CiderDarling is the default**. Regular Darling is available too.
Roblox downloads on first setup; settings, downloads and sign-in stay in
your writable user directories.

The package uses [Nixpkgs' FHS environment](https://nixos.org/manual/nixpkgs/stable/#sec-fhs-environments)
for Darling's Linux bridges and the same rootless helpers as Quinta's Flatpak.
It supplies the GTK/WebKit, graphics and audio libraries without installing
anything into `/usr` or `/opt`. You do not need a separate Darling package,
`nix-ld`, or a setuid Darling wrapper.

## Run or install

Enable `nix-command` and `flakes` in your Nix configuration:

```nix
nix.settings.experimental-features = [ "nix-command" "flakes" ];
hardware.graphics.enable = true;
```

The [NixOS graphics configuration](https://nixos.org/manual/nixos/stable/#sec-gpu-accel)
must provide your GPU driver. Keep your normal NVIDIA configuration if using
the proprietary driver. The launcher finds driver manifests and libraries
under `/run/opengl-driver`.

From a checkout:

```bash
nix run .                              # CiderDarling
nix run .#quinta-regular              # Regular Darling
nix build .                            # ./result/bin/quinta
nix profile add .#quinta              # Install with menu and URI handlers
```

You can replace `.` with `github:Quinta/Quinta` once this support is
published in that repository. The flake lock pins Nixpkgs, and runtime
downloads have fixed SHA-256 checksums. Builds do not fetch the mutable
CiderDarling update feed.

## NixOS module

Add Quinta to your system flake inputs, then import its module:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    quinta.url = "github:Quinta/Quinta";
  };

  outputs = { nixpkgs, quinta, ... }: {
    nixosConfigurations.my-host = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
        quinta.nixosModules.default
        {
          programs.quinta = {
            enable = true;
            runtime = "ciderdarling"; # Or "regular"
            # withStudio = true;     # Also include Wine for Roblox Studio
          };
        }
      ];
    };
  };
}
```

The module enables `hardware.graphics.enable` and installs desktop entries
and Roblox link handlers. To make Quinta your preferred link handler, add:

```nix
xdg.mime.defaultApplications = {
  "x-scheme-handler/roblox" = "io.github.imqstr.Quinta.URI.desktop";
  "x-scheme-handler/roblox-player" = "io.github.imqstr.Quinta.URI.desktop";
};
```

For Home Manager, add `quinta.packages.x86_64-linux.quinta` to
`home.packages` and enable graphics in the host's NixOS configuration.
The flake also exports `overlays.default`; the resulting `pkgs.quinta`
accepts `.override { runtime = "regular"; withStudio = true; }`.

## Runtime selection and updates

CiderDarling uses `~/.ciderdarling`, and regular Darling uses `~/.darling`.
Set `DPREFIX` to use a different prefix. Close Roblox and Darling before
changing runtimes. Nix ignores a saved native runtime selection without
rewriting it, so an old `/opt` installation or a garbage-collected store
path cannot replace the package's bundled runtime.

CiderDarling's graphics, threading and diagnostics settings remain available.
Runtime selection, downloads and rollback use your Nix configuration;
the launcher's runtime installer and updater are disabled for this package.
Update the `quinta` input with `nix flake update quinta`, then rebuild your
system. Use NixOS generations or Nix profile rollback to restore an earlier
package and its matching runtime. Prefix data is retained across upgrades.

The rootless runtime needs user namespaces enabled (the NixOS default).
This is a NixOS package; using it on other distributions may require extra
GPU integration. Wine is optional and is only included with `withStudio`.

## Maintainers

Run `nix flake check -L` to build both runtime variants. Their native payloads
compile the shim and guest frameworks against the bundled SDK, build the
locked Rust Metal host, and validate desktop entries.

Run `nix run .#check-runtime` and `nix run .#check-runtime-regular` to check
each packaged launcher and start a guest shell in a disposable prefix.
Successful checks shut down Darling and delete their temporary data; failed
checks keep the prefix for inspection. CI runs both checks after building.

`runtime-pins.json` pins the CiderDarling Ubuntu 24.04 archive, revision and
patch manifest from a complete published runtime release. Update all three
values together, verify its runtime metadata, and build both variants before
shipping. Regular Darling reads the existing pins from `install.sh`.
The Rust git dependency hash is in `metal-host.nix`; update it together with
the Metal host's `Cargo.lock`. `nix flake update nixpkgs` updates the build
and runtime libraries.
