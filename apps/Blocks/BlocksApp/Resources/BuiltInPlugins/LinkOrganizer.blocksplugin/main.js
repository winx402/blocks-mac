function organizeLink(event, context) {
  "use strict";
  if (context.configuration && context.configuration.remove_tracking === false) return { disposition: "allow" };
  var text = String((event.payload || {}).text || "").trim();
  if (!/^https?:\/\//i.test(text)) return { disposition: "allow" };
  var tracking = { utm_source: true, utm_medium: true, utm_campaign: true, utm_term: true, utm_content: true, gclid: true, fbclid: true, mc_cid: true, mc_eid: true };
  var hashIndex = text.indexOf("#");
  var fragment = hashIndex >= 0 ? text.slice(hashIndex) : "";
  var withoutFragment = hashIndex >= 0 ? text.slice(0, hashIndex) : text;
  var queryIndex = withoutFragment.indexOf("?");
  if (queryIndex < 0) return { disposition: "allow" };
  var base = withoutFragment.slice(0, queryIndex);
  var pairs = withoutFragment.slice(queryIndex + 1).split("&");
  var kept = pairs.filter(function (pair) {
    if (!pair) return false;
    var rawKey = pair.split("=", 1)[0].toLowerCase();
    return !tracking[rawKey];
  });
  var organized = base + (kept.length ? "?" + kept.join("&") : "") + fragment;
  if (organized === text) return { disposition: "allow" };
  return { disposition: "allow", mutations: [{ field: "text", value: organized }, { field: "plain_text", value: organized }] };
}
