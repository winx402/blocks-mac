function afterScreenshot(event) {
  "use strict";
  var resource = event.resources && event.resources[0];
  if (!resource) return { disposition: "allow", ui_state_patches: [{ component_id: "ocr-status", property: "value", operation: "replace", value: "No image resource was provided" }] };
  return { disposition: "allow", actions: [{ action_id: "screenshot.ocr", input: { resource_id: resource.id }, idempotency_key: event.event_id + ":ocr" }], ui_state_patches: [{ component_id: "ocr-status", property: "value", operation: "replace", value: "OCR requested" }] };
}
function handleOCRCompletion(event) {
  "use strict";
  var payload = event.payload || {};
  if (payload.action_id !== "screenshot.ocr") return { disposition: "allow" };
  var output = payload.output || {};
  var text = String(output.text || "");
  if (!text) return { disposition: "allow", ui_state_patches: [{ component_id: "ocr-status", property: "value", operation: "replace", value: "No text found" }] };
  blocks.storage.put("ocr", "latest", text, null);
  return { disposition: "allow", ui_state_patches: [{ component_id: "ocr-status", property: "value", operation: "replace", value: "Text recognized" }, { component_id: "ocr-preview", property: "value", operation: "replace", value: text }] };
}
function handleOCRFailure(event) {
  "use strict";
  var payload = event.payload || {};
  if (payload.action_id !== "screenshot.ocr") return { disposition: "allow" };
  return { disposition: "allow", ui_state_patches: [{ component_id: "ocr-status", property: "value", operation: "replace", value: "Recognition failed" }] };
}
function copyLatestOCR() {
  "use strict";
  var stored = blocks.storage.get("ocr", "latest");
  var text = stored && stored.value;
  if (!text) return { output: { copied: false } };
  return { output: { copied: true }, actions: [{ action_id: "clipboard.copy_text", input: { text: text } }] };
}
