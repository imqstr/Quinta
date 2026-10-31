{
  buildFHSEnv,
  writeShellScript,
  quinta,
}:
buildFHSEnv (
  quinta.args
  // {
    executableName = "quinta-runtime-check";
    extraInstallCommands = "";
    runScript = writeShellScript "quinta-runtime-check" ''
      set -euo pipefail
      test_root=$(mktemp -d /tmp/quinta-runtime-check.XXXXXX)
      export XDG_CONFIG_HOME="$test_root/config"
      export XDG_CACHE_HOME="$test_root/cache"
      export XDG_DATA_HOME="$test_root/data"
      export DPREFIX="$test_root/prefix"
      export QUINTA_PID1_DYLIB=${quinta.payload}/lib/quinta/launchd_pid1.dylib
      export LIBGL_ALWAYS_SOFTWARE=1
      command=(env LD_PRELOAD=${quinta.payload}/lib/quinta/darling-noroot.so /usr/bin/darling)
      cleanup() {
        status=$?
        timeout 10 "''${command[@]}" shutdown >/dev/null 2>&1 || true
        if [[ $status == 0 ]]; then
          rm -rf -- "$test_root"
        else
          printf 'Runtime check failed; prefix retained at %s\n' "$test_root" >&2
        fi
      }
      trap cleanup EXIT
      ${quinta.payload}/bin/quinta --hardware-report --help >/dev/null
      timeout 45 "''${command[@]}" shell /bin/echo "Quinta ${quinta.runtime} guest shell: PASS"
    '';
  }
)
