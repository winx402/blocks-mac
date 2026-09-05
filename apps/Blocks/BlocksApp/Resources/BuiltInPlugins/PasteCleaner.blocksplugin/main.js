function cleanPaste(event, context) {
  "use strict";
  var payload = event.payload || {};
  var config = context.configuration || {};
  var kind = String(payload.kind || "");
  if (kind && kind !== "text" && kind !== "rich_text" && kind !== "url") {
    return { disposition: "allow" };
  }
  var source = typeof payload.text === "string"
    ? payload.text
    : (typeof payload.plain_text === "string" ? payload.plain_text : null);
  if (source === null) return { disposition: "allow" };
  var text = source;
  if (config.normalize_line_breaks !== false) text = text.replace(/\r\n?/g, "\n");
  if (config.trim_outer_whitespace !== false) text = text.trim();
  if (config.collapse_blank_lines === true) text = text.replace(/\n{3,}/g, "\n\n");
  if (text === source && config.plain_text_only !== true) {
    return { disposition: "allow" };
  }
  var mutations = [{ field: "text", value: text }];
  if (config.plain_text_only === true) mutations.push({ field: "plain_text", value: text });
  return { disposition: "allow", mutations: mutations };
}
