#!/usr/bin/env bash
set -euo pipefail
host_name="au.com.pwnpc.tidytabs"
rm -f "$HOME/Library/Application Support/Aside/NativeMessagingHosts/$host_name.json" \
  "$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts/$host_name.json"
rm -rf "$HOME/Library/Application Support/TidyTabs"
echo "Removed Tidy Tabs' native host."
