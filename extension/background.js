// Tidy Tabs: groups the window's loose tabs (not pinned, not already in a group) by what they're for, using Apple
// Intelligence on this Mac through the native host in ../host.

import { VARIANT } from "./variant.js";

const HOST = "au.com.pwnpc.tidytabs";
// Group icons are an Aside addition to tabGroups.update; Chrome rejects the unknown property.
const SUPPORTS_GROUP_ICONS = VARIANT === "aside";
const MAX_TABS = 50; // Keeps the prompt inside the on-device model's context.
const UNDO_KEY = "lastTidy";
const ERROR_BADGE_MS = 6000;
const IDLE_TITLE = "Tidy Tabs: group loose tabs with Apple Intelligence";
const AUTO_KEY = "autoGroup"; // chrome.storage.local; on unless turned off.
const NEW_TABS_KEY = "newTabs"; // chrome.storage.session; tab IDs opened since, waiting for their first page to load.
// chrome.storage.session; group ID to the icon we gave it. Aside's tabGroups API can set an icon but doesn't report
// one, so this is how undoing a re-tidy can put icons back on the groups it restores.
const ICONS_KEY = "groupIcons";

let busy = false;

chrome.runtime.onInstalled.addListener(async () => {
  const auto = await autoGroupOn();
  chrome.contextMenus.create({ id: "retidy", title: "Re-tidy all tabs", contexts: ["action"] });
  chrome.contextMenus.create({ id: "undo", title: "Undo last tidy", contexts: ["action"], enabled: false });
  chrome.contextMenus.create({ id: "check", title: "Check Apple Intelligence", contexts: ["action"] });
  chrome.contextMenus.create({ id: AUTO_KEY, title: "Add new tabs to matching groups", type: "checkbox", checked: auto, contexts: ["action"] });
});

chrome.action.onClicked.addListener((tab) => tidy(tab.windowId));
chrome.commands.onCommand.addListener(async (command) => {
  if (command !== "tidy-tabs" && command !== "retidy-tabs") return;
  const window = await chrome.windows.getLastFocused();
  tidy(window.id, { everything: command === "retidy-tabs" });
});
chrome.contextMenus.onClicked.addListener((info, tab) => {
  if (info.menuItemId === "retidy" && tab) tidy(tab.windowId, { everything: true });
  if (info.menuItemId === "undo") undoLastTidy();
  if (info.menuItemId === "check") checkHost();
  if (info.menuItemId === AUTO_KEY) chrome.storage.local.set({ [AUTO_KEY]: info.checked });
});

// A tidy groups the loose tabs and leaves existing groups alone. A re-tidy (`everything`) also takes the tabs already
// in groups and regroups the lot from scratch; their old groups are only broken up once the model has answered, so a
// failed re-tidy changes nothing.
async function tidy(windowId, { everything = false } = {}) {
  if (busy) return; // One tidy at a time; clicks while the model works are ignored.
  setBusy(true);
  try {
    const tabs = await tidyCandidates(windowId, everything);
    if (tabs.length < 2) return showError(everything ? "There aren't enough tabs to tidy." : "There are no loose tabs to tidy.");
    const reply = await askHost({
      type: "tidy",
      tabs: tabs.map((tab) => ({ title: tab.title || tab.url, address: address(tab.url) })),
    });
    const groups = validGroups(reply.groups, tabs.length);
    if (!groups.length) return showError("No tabs clearly belonged together.");
    await applyGroups(windowId, tabs, groups);
  } catch (error) {
    showError(error.message);
  } finally {
    setBusy(false);
  }
}

// Web tabs a tidy considers, up to MAX_TABS: loose ones (not pinned, not in a group) or, for a re-tidy, every unpinned
// one. Past the cap, the rest stay as they are.
async function tidyCandidates(windowId, everything) {
  const query = everything ? { windowId, pinned: false } : { windowId, pinned: false, groupId: chrome.tabGroups.TAB_GROUP_ID_NONE };
  return (await chrome.tabs.query(query)).filter(isWebTab).slice(0, MAX_TABS);
}

function isWebTab(tab) {
  return /^https?:/.test(tab.url || "");
}

// The site and path, without the query or fragment, which are mostly tracking and session noise: "apple.com/iphone-duo".
function address(url) {
  const { hostname, pathname } = new URL(url);
  return (hostname.replace(/^www\./, "") + pathname.replace(/\/+$/, "")).slice(0, 70);
}

// The host's reply is untrusted input: keep valid, distinct, 1-based tab numbers, two or more to a group.
function validGroups(groups, tabCount) {
  if (!Array.isArray(groups)) throw new Error("The model's answer wasn't readable.");
  const used = new Set();
  const valid = [];
  for (const group of groups) {
    if (!group || !Array.isArray(group.tabs)) continue;
    const numbers = group.tabs.filter((n) => Number.isInteger(n) && n >= 1 && n <= tabCount && !used.has(n));
    numbers.forEach((n) => used.add(n));
    const icon = typeof group.icon === "string" && group.icon.length <= 16 ? group.icon : undefined;
    if (numbers.length >= 2) valid.push({ title: String(group.title || "").slice(0, 40), tabs: numbers, icon });
  }
  return valid;
}

async function applyGroups(windowId, tabs, groups) {
  // Saved first so a tidy that fails partway can still be undone. Only a re-tidy touches grouped tabs, so only it
  // has old groups to remember.
  const places = tabs.map((tab) => ({ id: tab.id, index: tab.index }));
  const oldGroups = await describeGroups(tabs);
  await chrome.storage.session.set({ [UNDO_KEY]: { windowId, places, oldGroups } });
  chrome.contextMenus.update("undo", { enabled: true });
  const grouped = tabs.filter((tab) => tab.groupId !== chrome.tabGroups.TAB_GROUP_ID_NONE).map((tab) => tab.id);
  if (grouped.length) await chrome.tabs.ungroup(grouped);
  for (const group of groups) {
    const tabIds = group.tabs.map((n) => tabs[n - 1].id);
    const groupId = await chrome.tabs.group({ tabIds, createProperties: { windowId } });
    await chrome.tabGroups.update(groupId, { title: group.title, collapsed: false });
    await setIcon(groupId, group.icon);
  }
}

// The groups these tabs are in, as enough to rebuild them: name, colour, icon if we set it, and member tabs.
async function describeGroups(tabs) {
  const { [ICONS_KEY]: icons = {} } = await chrome.storage.session.get(ICONS_KEY);
  const members = new Map();
  for (const tab of tabs) {
    if (tab.groupId === chrome.tabGroups.TAB_GROUP_ID_NONE) continue;
    members.set(tab.groupId, [...(members.get(tab.groupId) || []), tab.id]);
  }
  return Promise.all(
    [...members].map(async ([groupId, tabIds]) => {
      const group = await chrome.tabGroups.get(groupId);
      return { title: group.title, color: group.color, collapsed: group.collapsed, icon: icons[groupId], tabIds };
    }),
  );
}

// Aside's `icon` takes only its preset IDs, which the host restricts the model to. A failure here must not undo the
// grouping, so it's logged and the group keeps its name. Icons we set are remembered because the API can't read them.
async function setIcon(groupId, icon) {
  if (!icon || !SUPPORTS_GROUP_ICONS) return;
  try {
    await chrome.tabGroups.update(groupId, { icon });
    const { [ICONS_KEY]: icons = {} } = await chrome.storage.session.get(ICONS_KEY);
    await chrome.storage.session.set({ [ICONS_KEY]: { ...icons, [groupId]: icon } });
  } catch (error) {
    console.warn("Tidy Tabs: Aside didn't take the group icon", icon, error.message);
  }
}

// --- Adding new tabs to existing groups ---
//
// Only tabs opened after the extension started are considered, once, when their first page finishes loading (by then
// the title is known). Tabs you drag out of a group, or navigate later, are never moved again.

async function autoGroupOn() {
  const { [AUTO_KEY]: on } = await chrome.storage.local.get(AUTO_KEY);
  return on !== false;
}

chrome.tabs.onCreated.addListener(async (tab) => {
  if (tab.pinned || !(await autoGroupOn())) return;
  const { [NEW_TABS_KEY]: ids = [] } = await chrome.storage.session.get(NEW_TABS_KEY);
  await chrome.storage.session.set({ [NEW_TABS_KEY]: [...ids, tab.id].slice(-100) });
});

chrome.tabs.onRemoved.addListener((tabId) => forgetNewTab(tabId));

chrome.tabs.onUpdated.addListener(async (tabId, change, tab) => {
  if (change.status !== "complete" || !isWebTab(tab)) return;
  if (!(await forgetNewTab(tabId))) return;
  // Opened from a grouped tab, Chromium already put it in that group; pinned and tidying-in-progress tabs are left alone.
  if (tab.pinned || tab.groupId !== chrome.tabGroups.TAB_GROUP_ID_NONE || busy || !(await autoGroupOn())) return;
  queue(() => addToMatchingGroup(tab));
});

// True if the tab was waiting, and stops it waiting.
async function forgetNewTab(tabId) {
  const { [NEW_TABS_KEY]: ids = [] } = await chrome.storage.session.get(NEW_TABS_KEY);
  if (!ids.includes(tabId)) return false;
  await chrome.storage.session.set({ [NEW_TABS_KEY]: ids.filter((id) => id !== tabId) });
  return true;
}

// One model call at a time: several tabs opened together would otherwise start several helper processes at once.
let pending = Promise.resolve();
function queue(job) {
  pending = pending.then(job).catch((error) => console.warn("Tidy Tabs: auto-group:", error.message));
}

async function addToMatchingGroup(tab) {
  const groups = (await chrome.tabGroups.query({ windowId: tab.windowId })).filter((group) => group.title);
  if (!groups.length) return;
  const members = await Promise.all(
    groups.map((group) => chrome.tabs.query({ groupId: group.id }).then((tabs) => tabs.slice(0, 5).map((t) => t.title || t.url))),
  );
  const reply = await askHost({
    type: "assign",
    tab: { title: tab.title || tab.url, address: address(tab.url) },
    groups: groups.map((group, i) => ({ title: group.title, tabs: members[i] })),
  });
  const index = reply.group;
  if (!Number.isInteger(index) || index < 0 || index >= groups.length) return;
  // The tab may have been closed, grouped by hand or moved to another window while the model thought.
  const current = await chrome.tabs.get(tab.id).catch(() => null);
  if (!current || current.groupId !== chrome.tabGroups.TAB_GROUP_ID_NONE || current.windowId !== groups[index].windowId) return;
  await chrome.tabs.group({ groupId: groups[index].id, tabIds: tab.id });
}

// Ungroups what the last tidy grouped, puts each tab back where it was and, after a re-tidy, rebuilds the groups it
// broke up. Tabs closed since then are skipped.
async function undoLastTidy() {
  const { [UNDO_KEY]: last } = await chrome.storage.session.get(UNDO_KEY);
  if (!last) return;
  await chrome.storage.session.remove(UNDO_KEY);
  chrome.contextMenus.update("undo", { enabled: false });
  const open = new Set((await chrome.tabs.query({ windowId: last.windowId })).map((tab) => tab.id));
  const places = last.places.filter((place) => open.has(place.id)).sort((a, b) => a.index - b.index);
  if (!places.length) return;
  await chrome.tabs.ungroup(places.map((place) => place.id));
  for (const place of places) await chrome.tabs.move(place.id, { index: place.index });
  for (const old of last.oldGroups || []) {
    const tabIds = old.tabIds.filter((id) => open.has(id));
    if (!tabIds.length) continue;
    const groupId = await chrome.tabs.group({ tabIds, createProperties: { windowId: last.windowId } });
    await chrome.tabGroups.update(groupId, { title: old.title, color: old.color, collapsed: old.collapsed });
    await setIcon(groupId, old.icon);
  }
}

async function checkHost() {
  try {
    await askHost({ type: "status" });
    chrome.action.setBadgeBackgroundColor({ color: "#2a9d8f" });
    chrome.action.setBadgeText({ text: "ok" });
    setTimeout(() => chrome.action.setBadgeText({ text: "" }), 2000);
  } catch (error) {
    showError(error.message);
  }
}

async function askHost(request) {
  let reply;
  try {
    reply = await chrome.runtime.sendNativeMessage(HOST, request);
  } catch (error) {
    throw new Error(`Tidy Tabs' helper isn't installed. Run \`mise run install\`. (${error.message})`);
  }
  if (!reply || typeof reply !== "object") throw new Error("The helper sent an empty answer.");
  if (!reply.ok) throw new Error(String(reply.error || "The helper failed."));
  return reply;
}

function setBusy(on) {
  busy = on;
  chrome.action.setBadgeBackgroundColor({ color: "#2a9d8f" });
  chrome.action.setBadgeText({ text: on ? "…" : "" });
  chrome.action.setTitle({ title: on ? "Tidying tabs…" : IDLE_TITLE });
}

// Errors go in the badge and the button's tooltip.
function showError(message) {
  console.warn("Tidy Tabs:", message);
  // setBusy(false) runs in `finally` after this; defer so the error badge wins.
  setTimeout(() => {
    chrome.action.setBadgeBackgroundColor({ color: "#c0392b" });
    chrome.action.setBadgeText({ text: "!" });
    chrome.action.setTitle({ title: `Tidy Tabs: ${message}` });
    setTimeout(() => {
      if (busy) return;
      chrome.action.setBadgeText({ text: "" });
      chrome.action.setTitle({ title: IDLE_TITLE });
    }, ERROR_BADGE_MS);
  }, 0);
}
