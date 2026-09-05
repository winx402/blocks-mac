function captureFavorite(event) {
  "use strict";
  if ((event.payload || {}).is_favorite === false) return { disposition: "allow" };
  var payload = event.payload || {};
  var translations = Array.isArray(payload.translations) ? payload.translations : [];
  var first = translations[0] || {};
  var item = {
    title: String(payload.source_text || "Translation favorite"),
    detail: String(first.translated_text || "Ready for review"),
    source_language: payload.source_language || null,
    target_language: payload.target_language || null,
    favorite_id: payload.favorite_id || null
  };
  blocks.storage.queue.enqueue("reviews", "cards", item);
  return { disposition: "allow", ui_state_patches: [{ component_id: "queue", property: "items", operation: "append", value: item }, { component_id: "queue-status", property: "value", operation: "replace", value: "Cards ready" }] };
}
function markReviewed() { "use strict"; var item = blocks.storage.queue.dequeue("reviews", "cards"); return { output: { reviewed: item }, ui_state_patches: [{ component_id: "queue-status", property: "value", operation: "replace", value: item ? "Reviewed" : "No cards due" }] }; }
function dailyReview(event, context) {
  "use strict";
  var hour = Number((context.configuration || {}).review_hour);
  if (Number.isFinite(hour) && new Date().getHours() !== Math.max(0, Math.min(23, Math.round(hour)))) return {};
  return { actions: [{ action_id: "system.notification", input: { level: "info", title: "Word Cards", detail: "Your local review queue is ready.", deduplication_key: "word-cards-daily" } }] };
}
