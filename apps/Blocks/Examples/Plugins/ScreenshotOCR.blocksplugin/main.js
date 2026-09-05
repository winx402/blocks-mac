function afterScreenshot(event) {
  "use strict";
  return {
    actions: [{
      action_id: "screenshot.ocr",
      input: { resource_id: event.resources[0] && event.resources[0].id }
    }]
  };
}
