#!/usr/bin/env bash
# Builds the native host and registers it with each installed browser. Aside and Chrome each read Chromium-style
# native messaging manifests from their own Application Support folder.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
extension_id="cimghdibiabeacjigoedppjhjagggheh"  # Fixed by the "key" in extension/manifest.json, for both variants.
host_name="au.com.pwnpc.tidytabs"
install_dir="$HOME/Library/Application Support/TidyTabs"
browsers=(
  "$HOME/Library/Application Support/Aside"
  "$HOME/Library/Application Support/Google/Chrome"
)

swift build --package-path "$root/host" -c release
bin="$(swift build --package-path "$root/host" -c release --show-bin-path)/TidyTabsHost"
mkdir -p "$install_dir"
install -m 755 "$bin" "$install_dir/TidyTabsHost"
echo "Installed $install_dir/TidyTabsHost"

registered=0
for browser in "${browsers[@]}"; do
  [[ -d "$browser" ]] || continue
  mkdir -p "$browser/NativeMessagingHosts"
  cat > "$browser/NativeMessagingHosts/$host_name.json" <<JSON
{
  "name": "$host_name",
  "description": "Tidy Tabs: groups tabs with Apple Intelligence",
  "path": "$install_dir/TidyTabsHost",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://$extension_id/"]
}
JSON
  echo "Registered with $(basename "$browser")"
  registered=1
done
if [[ $registered == 0 ]]; then
  echo "Neither Aside nor Chrome has run on this Mac yet; open one, then run this again." >&2
  exit 1
fi
