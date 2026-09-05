function refresh(input) {
  "use strict";
  var uiState = input.ui_state || {};
  var messageState = uiState.message || {};
  var message = messageState.value || "Host-owned input";
  return {
    output: { refreshed: true, message: message },
    ui_state_patches: [
      {
        component_id: "status",
        property: "value",
        operation: "replace",
        value: "Updated by isolated JavaScript"
      },
      {
        component_id: "history",
        property: "items",
        operation: "append",
        value: {
          title: message,
          detail: "Rendered by Blocks"
        }
      }
    ]
  };
}
