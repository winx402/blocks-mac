function enforceTerms(event, context) {
  "use strict";
  var text = String((event.payload || {}).translated_text || "");
  var glossary = String((context.configuration || {}).glossary || "");
  if (!glossary.trim()) return { disposition: "allow" };
  var sensitive = (context.configuration || {}).case_sensitive === true;
  glossary.split(/\r?\n/).forEach(function (line) {
    var split = line.indexOf("="); if (split <= 0) return;
    var source = line.slice(0, split).trim(); var target = line.slice(split + 1).trim();
    if (!source || !target) return;
    var escaped = source.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    text = text.replace(new RegExp(escaped, sensitive ? "g" : "gi"), target);
  });
  return { disposition: "allow", mutations: [{ field: "translated_text", value: text }] };
}
