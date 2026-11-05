# Tidy Tabs

A browser extension for Aside and Chrome on the Mac. It groups your tabs by what they're for,
using Apple Intelligence on your Mac. Tab titles and addresses go only to Apple's on-device model.

- **Tidy:** click the toolbar button or press <kbd>⌥⇧T</kbd>. Loose tabs (not pinned, not in a group) are sorted into
  named groups. In Aside, each group also gets an icon.
- **Re-tidy all tabs:** on the button's right-click menu, or <kbd>⌥⇧R</kbd>. Every unpinned tab, including tabs
  already in groups, is regrouped from scratch. Your existing groups are only broken up after the model has
  answered.
- **New tabs join matching groups:** once a new tab finishes loading, it moves into the window's group that fits it,
  if any does. Each tab is checked once, so a tab you drag out of a group stays out. You can turn this off on the
  right-click menu.
- **Undo last tidy:** on the right-click menu. It puts tabs back where they were and rebuilds the groups a re-tidy
  broke up.

The badge shows `…` while the model is working and `!` when something fails. Hover over the button to read why.

## Requirements

- An Apple silicon Mac on macOS 26 or later, with Apple Intelligence turned on
- Xcode (to build the native host)
- Aside or Google Chrome

## Install

1. Build the native host and register it with Aside and Chrome:

   ```sh
   mise run install
   ```

2. Load the extension. Download `tidy-tabs-aside-*.zip` or `tidy-tabs-chrome-*.zip` from
   [Releases](../../releases), or run `mise run build` to build both into `dist/`. Unzip it, open
   `chrome://extensions`, turn on **Developer mode**, choose **Load unpacked**, and select the folder. To run the
   Aside build straight from source, select `extension/` instead.

The `.crx` files are signed with the project key. Chrome only installs a CRX from outside the Web Store through
[enterprise policy](https://support.google.com/chrome/a/answer/7532015), so for personal use, load the zip
unpacked. Both variants share the extension ID `cimghdibiabeacjigoedppjhjagggheh`, the only one the native host
accepts.

## How it works

A browser can't call Apple's model, so the extension (`extension/`) talks to a small Swift
[native messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging) host (`host/`)
that uses the FoundationModels framework.

A tidy makes two model calls:

1. **Plan.** The model reads every tab and names the groups worth making, each with an icon.
2. **Sort.** Each tab gets its own answer field, and the schema limits that answer to one of the planned names or
   "none". The model can't invent a group or mix up tabs.

Groups with fewer than two tabs are dropped. Sampling is greedy, so the same tabs always give the same groups.

Placing a new tab is a single call. The tab's answer is limited to the window's existing group names or "none",
and the model is told that being on the same website isn't enough to join a group.

The host logs every request and model answer to `~/Library/Logs/TidyTabs/host.log` on your Mac.

### Aside group icons

Aside adds an undocumented `icon` property to `chrome.tabGroups.update`. It accepts only the 28 preset IDs from
Aside's icon picker, such as `bubble`, `chart`, `suitcase` and `headphones`, and silently ignores anything else,
emoji included. The list, with the meaning that steers the model, is in `host/Sources/TidyTabsHost/Grouping.swift`.
The Chrome build skips icons, because Chrome rejects the property.

## Development

```sh
mise run test       # host unit tests
mise run build      # dist/: unpacked, zip and (with a key) CRX for each variant
mise run install    # rebuild and re-register the host
mise run uninstall  # remove the host and its registrations
```

`extension/variant.js` selects the browser; the build rewrites it for each variant. CRX signing reads the key from
the `CRX_PRIVATE_KEY` environment variable (as CI does) or from `keys/tidy-tabs.pem`, and it must match the `key`
in the manifest. Without a key, the build writes zips only.

CI tests and builds the host on macOS, and builds both extension variants on every push. Pushing a `v*` tag
publishes a release with the CRX and zip files and the arm64 host binary.

## License

MIT
