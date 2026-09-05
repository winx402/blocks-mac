function observeLaunch() {
  "use strict";
  const stored = blocks.storage.get("default", "launch_count");
  const count = stored && stored.value ? stored.value : 0;
  blocks.storage.put(
    "default",
    "launch_count",
    count + 1,
    stored && stored.revision ? stored.revision : null
  );
  blocks.sharedState.put(
    "com.blocks.examples.hook-policies",
    "public-counter",
    "launch_count",
    1,
    count + 1
  );
  return { disposition: "allow" };
}

function reviewShortcut(event) {
  "use strict";
  return event.payload && event.payload.disabled === true
    ? { disposition: "block", reason: "The shortcut is disabled by policy." }
    : { disposition: "allow" };
}

function readCounter() {
  "use strict";
  return { output: { counter: blocks.storage.get("default", "launch_count") } };
}

function observeSharedState(event) {
  "use strict";
  if (!event.payload || event.payload.owner_plugin_id === "com.blocks.examples.hook-policies") {
    return { disposition: "allow" };
  }
  blocks.storage.queue.enqueue("events", "shared-state", {
    owner_plugin_id: event.payload.owner_plugin_id,
    namespace: event.payload.namespace,
    key: event.payload.key,
    revision: event.payload.revision
  });
  return { disposition: "allow" };
}

function dequeueEvent() {
  "use strict";
  return { output: blocks.storage.queue.dequeue("events", "shared-state") };
}
