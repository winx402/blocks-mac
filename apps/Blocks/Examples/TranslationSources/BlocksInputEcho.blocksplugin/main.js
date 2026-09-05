function translate(input, context) {
  "use strict";

  blocks.progress({
    kind: "status",
    code: "echo_preparing",
    text: "Preparing the invocation echo."
  });

  const attachments = Array.isArray(input.attachments)
    ? input.attachments.map((attachment) => ({
        id: attachment.id ?? null,
        kind: attachment.kind ?? null,
        media_type: attachment.media_type ?? null,
        pixel_width: attachment.pixel_width ?? null,
        pixel_height: attachment.pixel_height ?? null,
        byte_count: attachment.byte_count ?? null,
        sha256: attachment.sha256 ?? null
      }))
    : [];

  const echoedInput = {
    text: input.text ?? null,
    source_language: input.source_language ?? null,
    target_language: input.target_language ?? null,
    input_source: input.context?.input_source ?? null,
    source_application_bundle_id:
      input.context?.source_application_bundle_id ?? null,
    ocr_summary: input.context?.ocr_summary ?? null,
    attachments
  };
  const echoedContext = {
    request_id: context.requestID,
    session_id: context.configuration?.session_id ?? null,
    capability: context.capability,
    configuration: context.configuration ?? {}
  };
  const text = JSON.stringify(
    { input: echoedInput, context: echoedContext },
    null,
    2
  );

  if (text.length > 256 * 1024) {
    return {
      status: "failed",
      text: "",
      error_code: "echo_output_too_large",
      error_message: "The complete invocation echo exceeds 256 KB.",
      is_retryable: false
    };
  }

  blocks.progress({
    kind: "status",
    code: "echo_completed",
    text: "Invocation echo is ready."
  });
  return {
    status: "completed",
    text,
    metadata: {
      echo: true,
      attachment_count: attachments.length
    }
  };
}
