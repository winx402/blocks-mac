function inspectCapture(event) {
  "use strict";
  var text = String((event.payload || {}).text || (event.payload || {}).summary || "").trim();
  var config = (arguments.length > 1 && arguments[1].configuration) || {};
  var type = null;
  if (/^[0-9a-f]{8}-[0-9a-f-]{27}$/i.test(text)) type = "UUID";
  else if (/^eyJ[\w-]+\.[\w-]+\.[\w-]+$/.test(text)) type = "JWT (decoded only, not verified)";
  else if (/^[0-9a-f]{32,128}$/i.test(text)) type = "Hash";
  else if (/^(#(?:[0-9a-f]{3,8})|rgba?\(|hsla?\()/i.test(text)) type = "Color";
  else if (config.detect_base64 !== false && text.length >= 8 && text.length % 4 === 0 && /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(text)) {
    type = "Base64";
  }
  else { try { JSON.parse(text); type = "JSON"; } catch (_) {} }
  if (!type) return { disposition: "allow" };
  return { disposition: "allow", ui_state_patches: [{ component_id: "status", property: "value", operation: "replace", value: type }, { component_id: "history", property: "items", operation: "append", value: { title: type, detail: "Recognized locally" } }] };
}
function clearFindings() { "use strict"; return { ui_state_patches: [{ component_id: "history", property: "items", operation: "replace", value: [] }, { component_id: "status", property: "value", operation: "replace", value: "Waiting for local content" }] }; }
