function handlePaste(event, context) {
  "use strict";
  const recordID = event && event.payload && event.payload.record_id;
  if (!recordID) {
    return {
      diagnostics: [{
        level: "warning",
        code: "record_missing",
        message: "The paste event did not include a record ID."
      }]
    };
  }
  return {
    disposition: "allow",
    actions: [{
      action_id: "clipboard.tag.ensure_and_attach",
      input: {
        record_id: recordID,
        name: context.configuration.tag_name || "Pasted by Blocks"
      },
      idempotency_key: event.event_id + ":tag"
    }]
  };
}
