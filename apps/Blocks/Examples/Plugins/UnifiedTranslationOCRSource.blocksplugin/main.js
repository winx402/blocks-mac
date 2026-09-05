function translate(input, context) {
  "use strict";
  blocks.progress({
    kind: "status",
    code: "translation_example_running",
    text: "Preparing the example translation result."
  });
  return {
    status: "completed",
    text: JSON.stringify({
      capability: context.capability,
      text: input.text ?? "",
      source_language: input.source_language ?? null,
      target_language: input.target_language ?? null
    }, null, 2),
    metadata: { example: true }
  };
}

function ocr(input, context) {
  "use strict";
  blocks.progress({
    kind: "status",
    code: "ocr_example_running",
    text: "Inspecting the authorized screenshot attachment."
  });
  const attachments = Array.isArray(input.attachments)
    ? input.attachments
    : [];
  return {
    status: "completed",
    text: JSON.stringify({
      capability: context.capability,
      attachment_count: attachments.length,
      attachments: attachments.map((item) => ({
        id: item.id ?? null,
        media_type: item.media_type ?? null,
        pixel_width: item.pixel_width ?? null,
        pixel_height: item.pixel_height ?? null,
        byte_count: item.byte_count ?? null,
        sha256: item.sha256 ?? null
      }))
    }, null, 2),
    metadata: { example: true }
  };
}
