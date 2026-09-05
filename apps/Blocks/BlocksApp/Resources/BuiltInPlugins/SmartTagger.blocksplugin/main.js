function classifyCapture(event, context) {
  "use strict";
  var payload = event.payload || {};
  var text = String(payload.text || payload.summary || "");
  var recordID = payload.record_id;
  if (!recordID) return { disposition: "allow" };
  var config = context.configuration || {};
  var tag = null;
  if (config.tag_links !== false && /^https?:\/\//i.test(text.trim())) tag = "Link";
  else if (config.tag_json !== false && /^[\[{]/.test(text.trim())) { try { JSON.parse(text); tag = "JSON"; } catch (_) {} }
  if (!tag && config.tag_colors !== false && /^(#(?:[0-9a-f]{3,8})|rgba?\(|hsla?\()/i.test(text.trim())) tag = "Color";
  if (!tag && config.tag_files !== false && payload.kind === "file") tag = "File";
  if (!tag && config.tag_code !== false && /(?:\bfunc\b|\bclass\b|=>|\{[\s\S]*\})/.test(text)) tag = "Code";
  if (!tag) return { disposition: "allow" };
  return { disposition: "allow", actions: [{ action_id: "clipboard.tag.ensure_and_attach", input: { record_id: recordID, name: tag }, idempotency_key: event.event_id + ":" + tag }] };
}
