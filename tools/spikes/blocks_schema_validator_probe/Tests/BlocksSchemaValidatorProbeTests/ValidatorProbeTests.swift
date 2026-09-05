import Foundation
import JSONSchema
import XCTest

final class ValidatorProbeTests: XCTestCase {
    func testDraft202012Basics() throws {
        try assertValid(schema: #"{"type":"string"}"#, instance: #""hello""#)
        try assertInvalid(schema: #"{"type":"string"}"#, instance: #"42"#)

        let objectSchema = """
        {
          "type": "object",
          "required": ["name"],
          "additionalProperties": false,
          "properties": {
            "name": {"type": "string"},
            "kind": {"enum": ["fixture"]},
            "version": {"const": "0.1.0"},
            "count": {"type": "integer", "minimum": 1}
          }
        }
        """
        try assertValid(
            schema: objectSchema,
            instance: #"{"name":"Blocks","kind":"fixture","version":"0.1.0","count":1}"#
        )
        try assertInvalid(schema: objectSchema, instance: #"{"kind":"fixture","version":"0.1.0","count":1}"#)
        try assertInvalid(
            schema: objectSchema,
            instance: #"{"name":"Blocks","kind":"fixture","version":"0.1.0","count":1,"extra":true}"#
        )
        try assertInvalid(
            schema: objectSchema,
            instance: #"{"name":"Blocks","kind":"other","version":"0.1.0","count":1}"#
        )
        try assertInvalid(
            schema: objectSchema,
            instance: #"{"name":"Blocks","kind":"fixture","version":"0.2.0","count":1}"#
        )
        try assertInvalid(
            schema: objectSchema,
            instance: #"{"name":"Blocks","kind":"fixture","version":"0.1.0","count":0}"#
        )
    }

    func testLocalRefWithinSchema() throws {
        let schema = """
        {
          "$schema": "https://json-schema.org/draft/2020-12/schema",
          "$defs": {
            "positiveInteger": {"type": "integer", "minimum": 1}
          },
          "type": "object",
          "required": ["limit"],
          "properties": {
            "limit": {"$ref": "#/$defs/positiveInteger"}
          }
        }
        """
        try assertValid(schema: schema, instance: #"{"limit":5}"#)
        try assertInvalid(schema: schema, instance: #"{"limit":0}"#)
    }

    func testProjectActionOutputFixtures() throws {
        let schemaRoot = repoRoot()
            .appendingPathComponent("docs/技术知识库/action-schemas", isDirectory: true)
        let cases = [
            (
                "actions/blocks.translate.text.output.schema.json",
                "examples/blocks-translate-text-success.json"
            ),
            (
                "actions/blocks.clipboard.search.output.schema.json",
                "examples/blocks-clipboard-search-success.json"
            ),
            (
                "actions/blocks.screenshot.capture.output.schema.json",
                "examples/blocks-screenshot-capture-success.json"
            )
        ]

        for (schemaRelativePath, exampleRelativePath) in cases {
            let schema = try String(
                contentsOf: schemaRoot.appendingPathComponent(schemaRelativePath),
                encoding: .utf8
            )
            let exampleData = try Data(contentsOf: schemaRoot.appendingPathComponent(exampleRelativePath))
            let example = try XCTUnwrap(JSONSerialization.jsonObject(with: exampleData) as? [String: Any])
            let result = try XCTUnwrap(example["result"])
            try assertValid(schema: schema, instance: jsonString(result))
        }
    }

    func testProjectHookManifestFixtures() throws {
        let schemaRoot = repoRoot()
            .appendingPathComponent("docs/技术知识库/action-schemas", isDirectory: true)
        let schema = try String(
            contentsOf: schemaRoot.appendingPathComponent("hooks/hook-manifest.schema.json"),
            encoding: .utf8
        )
        for example in [
            "examples/hook-sensitive-clipboard-review.json",
            "examples/hook-screenshot-ocr-suggestion.json"
        ] {
            let data = try Data(contentsOf: schemaRoot.appendingPathComponent(example))
            let instance = try XCTUnwrap(JSONSerialization.jsonObject(with: data))
            try assertValid(schema: schema, instance: jsonString(instance))
        }
    }

    private func repoRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 {
            url.deleteLastPathComponent()
        }
        return url
    }

    private func jsonString(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    private func assertValid(schema: String, instance: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let schema = try Schema(instance: schema)
        let result = try schema.validate(instance: instance)
        XCTAssertTrue(result.isValid, file: file, line: line)
    }

    private func assertInvalid(schema: String, instance: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let schema = try Schema(instance: schema)
        let result = try schema.validate(instance: instance)
        XCTAssertFalse(result.isValid, file: file, line: line)
    }
}
