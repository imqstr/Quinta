
project=$1 shim_dir=$2 launch_uri=$3; shift 3
unset MACOBLOX_METAL MACOBLOX_METAL_FRAMEWORKS MACOBLOX_METAL_HOST_LIBRARY MACOBLOX_METAL_SHADER_CACHE DYLD_FRAMEWORK_PATH
for kv in "$@"; do export "$kv"; done
# Roblox's own frame rate limit (FramerateCap, its Maximum Frame Rate
# setting), from the launcher's FPS limit. Set here, inside Darling, right
# before the game starts: Roblox rewrites the file when it quits, and a file
# in the prefix replaced from the host is not always seen by a running
# Darling. Bash only (3.2), which splits ${var/a/b} at a "/" even inside
# quotes, so the patterns come from variables.
case ${QUINTA_FRAMERATE_CAP:-} in
  '' | 0 | *[!0-9]*) ;;
  *)
    cap_file="$HOME/Library/Roblox/GlobalBasicSettings_13.xml"
    if [ -f "$cap_file" ]; then
      content=$(<"$cap_file")
      wanted="<int name=\"FramerateCap\">$QUINTA_FRAMERATE_CAP</int>"
      pattern='<int name="FramerateCap">-?[0-9]+</int>'
      if [[ $content =~ $pattern ]]; then
        old=${BASH_REMATCH[0]}
        content=${content/$old/$wanted}
      else
        close='</Properties>'
        insert=$'\t'"$wanted"$'\n\t\t</Properties>'
        content=${content/$close/$insert}
      fi
      printf '%s\n' "$content" > "$cap_file"
    fi ;;
esac
app="$project/RobloxPlayer.app/Contents/MacOS"
cd "$app" || exit 1
# Nothing may run between these exports and exec: every program started
# after them would get the shim injected too.
export DYLD_FORCE_FLAT_NAMESPACE=1
export DYLD_INSERT_LIBRARIES="$shim_dir/libQuintaShims.dylib"
export DYLD_LIBRARY_PATH="$shim_dir:$app"
if [ -n "${MACOBLOX_METAL_FRAMEWORKS:-}" ]; then
  export DYLD_FRAMEWORK_PATH="$MACOBLOX_METAL_FRAMEWORKS"
fi
if [ -n "$launch_uri" ]; then
  # Roblox's native macOS browser handoff is the -protocolString argument.
  # Keep the value as one opaque argument; the client owns the protocol
  # format. The shim logs this argument and suppresses Cocoa reinjection when
  # it is present, so one launch has one URL delivery path.
  export QUINTA_PENDING_URI="$launch_uri"
  exec ./RobloxPlayer -protocolString "$launch_uri"
fi
exec ./RobloxPlayer
