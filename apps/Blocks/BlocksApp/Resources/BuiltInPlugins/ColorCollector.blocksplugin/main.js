function normalizedColor(text) {
  "use strict";
  var value = String(text || "").trim();
  return /^(#(?:[0-9a-f]{3,8})|rgba?\([^\n]+\)|hsla?\([^\n]+\))$/i.test(value) ? value : null;
}
function saveColor(value) {
  "use strict";
  if (!value) return { disposition: "allow" };
  var snapshot = blocks.storage.get("palette", "items");
  var items = snapshot && Array.isArray(snapshot.value) ? snapshot.value.slice() : [];
  var normalized = value.toLowerCase();
  items = items.filter(function (item) { return String(item.value || "").toLowerCase() !== normalized; });
  items.unshift({ value: value });
  if (items.length > 50) items = items.slice(0, 50);
  blocks.storage.put("palette", "items", items, snapshot && snapshot.revision != null ? snapshot.revision : null);
  blocks.storage.put("palette", "latest", value, null);
  return { disposition: "allow", ui_state_patches: [{ component_id: "palette-status", property: "value", operation: "replace", value: value }, { component_id: "palette-list", property: "items", operation: "replace", value: items.map(function (item) { return { title: item.value, detail: "Collected locally" }; }) }] };
}
function collectColor(event) { "use strict"; return saveColor(normalizedColor((event.payload || {}).text || (event.payload || {}).summary)); }
function pickColor(event) { "use strict"; return { actions: [{ action_id: "screenshot.color_sample.begin", input: { operation_id: event.request_id || null } }] }; }
function collectSample(event) { "use strict"; var payload = event.payload || {}; if (payload.action_id !== "screenshot.color_sample.begin") return { disposition: "allow" }; return saveColor(payload.output && payload.output.hex); }
function copyLatest() { "use strict"; var stored = blocks.storage.get("palette", "latest"); if (!stored || !stored.value) return { output: { copied: false } }; return { output: { copied: true }, actions: [{ action_id: "clipboard.copy_text", input: { text: stored.value } }] }; }
function restorePalette() {
  "use strict";
  var snapshot = blocks.storage.get("palette", "items");
  var items = snapshot && Array.isArray(snapshot.value) ? snapshot.value : [];
  return { disposition: "allow", ui_state_patches: [{ component_id: "palette-status", property: "value", operation: "replace", value: items.length ? items[0].value : "No colors collected" }, { component_id: "palette-list", property: "items", operation: "replace", value: items.map(function (item) { return { title: item.value, detail: "Collected locally" }; }) }] };
}
