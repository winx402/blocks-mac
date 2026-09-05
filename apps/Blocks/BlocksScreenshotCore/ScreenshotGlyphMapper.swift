import CoreGraphics
import Foundation

struct ScreenshotGlyphMapper {
    private let bytes: [UInt8]
    private let subtableOffset: Int
    private let format: UInt16

    init?(font: CGFont) {
        guard let table = font.table(for: 0x636D_6170) else {
            return nil
        }
        let bytes = [UInt8](table as Data)
        guard let tableCount = Self.readUInt16(bytes, at: 2) else {
            return nil
        }

        var format4Offset: Int?
        var format12Offset: Int?
        for index in 0..<Int(tableCount) {
            let recordOffset = 4 + index * 8
            guard let offset = Self.readUInt32(bytes, at: recordOffset + 4) else {
                continue
            }
            let subtableOffset = Int(offset)
            guard let format = Self.readUInt16(bytes, at: subtableOffset) else {
                continue
            }
            if format == 12 {
                format12Offset = subtableOffset
            } else if format == 4, format4Offset == nil {
                format4Offset = subtableOffset
            }
        }

        if let format12Offset {
            self.bytes = bytes
            subtableOffset = format12Offset
            format = 12
        } else if let format4Offset {
            self.bytes = bytes
            subtableOffset = format4Offset
            format = 4
        } else {
            return nil
        }
    }

    func glyph(for scalar: Unicode.Scalar) -> CGGlyph {
        switch format {
        case 12:
            return glyphFromFormat12(for: scalar.value)
        case 4 where scalar.value <= UInt16.max:
            return glyphFromFormat4(for: UInt16(scalar.value))
        default:
            return 0
        }
    }

    private func glyphFromFormat12(for codePoint: UInt32) -> CGGlyph {
        guard let groupCount = Self.readUInt32(bytes, at: subtableOffset + 12) else {
            return 0
        }
        for index in 0..<Int(groupCount) {
            let groupOffset = subtableOffset + 16 + index * 12
            guard let start = Self.readUInt32(bytes, at: groupOffset),
                  let end = Self.readUInt32(bytes, at: groupOffset + 4),
                  let firstGlyph = Self.readUInt32(bytes, at: groupOffset + 8) else {
                return 0
            }
            if codePoint < start {
                return 0
            }
            if codePoint <= end {
                let value = firstGlyph + codePoint - start
                return value <= UInt16.max ? CGGlyph(value) : 0
            }
        }
        return 0
    }

    private func glyphFromFormat4(for codePoint: UInt16) -> CGGlyph {
        guard let segmentCountX2 = Self.readUInt16(bytes, at: subtableOffset + 6) else {
            return 0
        }
        let segmentCount = Int(segmentCountX2 / 2)
        let endCodesOffset = subtableOffset + 14
        let startCodesOffset = endCodesOffset + segmentCount * 2 + 2
        let deltasOffset = startCodesOffset + segmentCount * 2
        let rangesOffset = deltasOffset + segmentCount * 2

        for index in 0..<segmentCount {
            guard let end = Self.readUInt16(bytes, at: endCodesOffset + index * 2) else {
                return 0
            }
            if codePoint > end {
                continue
            }
            guard let start = Self.readUInt16(bytes, at: startCodesOffset + index * 2),
                  codePoint >= start,
                  let deltaBits = Self.readUInt16(bytes, at: deltasOffset + index * 2),
                  let rangeOffset = Self.readUInt16(bytes, at: rangesOffset + index * 2) else {
                return 0
            }
            let delta = Int32(Int16(bitPattern: deltaBits))
            if rangeOffset == 0 {
                return CGGlyph((Int32(codePoint) + delta) & 0xFFFF)
            }

            let glyphAddress = rangesOffset
                + index * 2
                + Int(rangeOffset)
                + Int(codePoint - start) * 2
            guard let glyph = Self.readUInt16(bytes, at: glyphAddress), glyph != 0 else {
                return 0
            }
            return CGGlyph((Int32(glyph) + delta) & 0xFFFF)
        }
        return 0
    }

    private static func readUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 1 < bytes.count else {
            return nil
        }
        return UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 3 < bytes.count else {
            return nil
        }
        return UInt32(bytes[offset]) << 24
            | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8
            | UInt32(bytes[offset + 3])
    }
}
