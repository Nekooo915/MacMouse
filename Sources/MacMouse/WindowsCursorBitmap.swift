import CoreGraphics
import Foundation
import ImageIO

enum CursorBitmap {
    private typealias ParseError = WindowsCursorParser.ParseError
    private static let pngSignature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]

    static func decode(
        _ bytes: CursorBytes, expectedHeight: Int, budget: inout WindowsCursorParser.DecodeBudget
    ) throws -> CGImage {
        guard bytes.count <= 8 * 1024 * 1024 else { throw ParseError.sizeLimit }
        if bytes.storage.starts(with: pngSignature) {
            return try decodePNG(bytes, budget: &budget)
        }
        let bitmap = try Bitmap(bytes, expectedHeight: expectedHeight, budget: &budget)
        return try bitmap.makeImage()
    }

    private static func decodePNG(
        _ bytes: CursorBytes, budget: inout WindowsCursorParser.DecodeBudget
    ) throws -> CGImage {
        guard bytes.count >= 33, bytes.dword(at: 8).byteSwapped == 13, bytes.tag(at: 12) == "IHDR" else {
            throw ParseError.invalidImage
        }
        let width = Int(bytes.dword(at: 16).byteSwapped)
        let height = Int(bytes.dword(at: 20).byteSwapped)
        try budget.reserve(width: width, height: height)
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let source = CGImageSourceCreateWithData(Data(bytes.storage) as CFData, nil),
              CGImageSourceGetStatus(source) == .statusComplete,
              let image = CGImageSourceCreateImageAtIndex(source, 0, options),
              image.width == width, image.height == height else {
            throw ParseError.invalidImage
        }
        return image
    }

    private struct Color {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
        var alpha: UInt8 = 255
    }

    private struct ChannelMask {
        let mask: UInt32
        let shift: Int
        let maxValue: UInt32

        init(_ mask: UInt32) throws {
            guard mask != 0 else { throw ParseError.invalidImage }
            let shift = mask.trailingZeroBitCount
            let value = mask >> shift
            guard value & (value &+ 1) == 0 else { throw ParseError.invalidImage }
            self.mask = mask
            self.shift = shift
            self.maxValue = value
        }

        func component(_ pixel: UInt32) -> UInt8 {
            let value = UInt64((pixel & mask) >> shift)
            return UInt8((value * 255 + UInt64(maxValue / 2)) / UInt64(maxValue))
        }
    }

    private struct BitFields {
        let red: ChannelMask
        let green: ChannelMask
        let blue: ChannelMask
        let alpha: ChannelMask?

        init(red: UInt32, green: UInt32, blue: UInt32, alpha: UInt32 = 0, depth: Int) throws {
            let validBits = UInt32.max >> (32 - depth)
            guard (red | green | blue | alpha) & ~validBits == 0,
                  red & (green | blue | alpha) == 0, green & (blue | alpha) == 0, blue & alpha == 0 else {
                throw ParseError.invalidImage
            }
            self.red = try ChannelMask(red)
            self.green = try ChannelMask(green)
            self.blue = try ChannelMask(blue)
            self.alpha = alpha == 0 ? nil : try ChannelMask(alpha)
        }

        func color(_ pixel: UInt32) -> Color {
            Color(red: red.component(pixel), green: green.component(pixel),
                  blue: blue.component(pixel), alpha: alpha?.component(pixel) ?? 255)
        }
    }

    private enum Encoding {
        case rgb
        case bitFields(BitFields)
        case rle
    }

    private struct Bitmap {
        let bytes: CursorBytes
        let width: Int
        let height: Int
        let topDown: Bool
        let depth: Int
        let encoding: Encoding
        let palette: [Color]
        let pixelOffset: Int
        let maskOffset: Int?
        let colorStride: Int
        let maskStride: Int
        let rleIndices: [UInt8]?

        init(_ bytes: CursorBytes, expectedHeight: Int, budget: inout WindowsCursorParser.DecodeBudget) throws {
            guard bytes.count >= 12 else { throw ParseError.invalidImage }
            let headerSize = Int(bytes.dword(at: 0))
            guard [12, 40, 52, 56, 108, 124].contains(headerSize), headerSize <= bytes.count else {
                throw ParseError.unsupportedBitmap
            }

            let coreHeader = headerSize == 12
            let width = coreHeader ? bytes.word(at: 4) : bytes.signedDword(at: 4)
            let storedHeight = coreHeader ? bytes.word(at: 6) : bytes.signedDword(at: 8)
            let planes = bytes.word(at: coreHeader ? 8 : 12)
            let depth = bytes.word(at: coreHeader ? 10 : 14)
            let compression = coreHeader ? 0 : bytes.dword(at: 16)
            guard width > 0, storedHeight != 0, planes == 1 else { throw ParseError.invalidImage }
            guard width <= 512, abs(storedHeight) <= 1024 else { throw ParseError.sizeLimit }
            guard [1, 4, 8, 16, 24, 32].contains(depth) else { throw ParseError.unsupportedBitmap }

            var paletteOffset = headerSize
            let encoding: Encoding
            switch compression {
            case 0:
                if depth == 16 {
                    encoding = .bitFields(try BitFields(red: 0x7C00, green: 0x03E0, blue: 0x001F, depth: depth))
                } else {
                    encoding = .rgb
                }
            case 1 where depth == 8 && storedHeight > 0,
                 2 where depth == 4 && storedHeight > 0:
                encoding = .rle
            case 3 where depth == 16 || depth == 32,
                 6 where depth == 16 || depth == 32:
                let hasAlphaMask = headerSize >= 56 || compression == 6
                let maskEnd = hasAlphaMask ? 56 : 52
                guard bytes.count >= maskEnd, headerSize == 40 || headerSize >= maskEnd else {
                    throw ParseError.invalidImage
                }
                if headerSize == 40 { paletteOffset = maskEnd }
                let alpha = hasAlphaMask ? bytes.dword(at: 52) : 0
                guard compression != 6 || alpha != 0 else { throw ParseError.invalidImage }
                encoding = .bitFields(try BitFields(red: bytes.dword(at: 40), green: bytes.dword(at: 44),
                                                   blue: bytes.dword(at: 48), alpha: alpha, depth: depth))
            default:
                throw ParseError.unsupportedBitmap
            }

            let paletteEntrySize = coreHeader ? 3 : 4
            let specifiedColors = coreHeader ? 0 : Int(bytes.dword(at: 32))
            let maxPalette = depth <= 8 ? 1 << depth : 0
            let paletteCount = specifiedColors == 0 ? maxPalette : specifiedColors
            guard (maxPalette == 0 || paletteCount <= maxPalette),
                  paletteCount <= (bytes.count - paletteOffset) / paletteEntrySize else {
                throw ParseError.invalidImage
            }
            let pixelOffset = paletteOffset + paletteCount * paletteEntrySize
            let colorStride = ((width * depth + 31) / 32) * 4
            let maskStride = ((width + 31) / 32) * 4
            let absoluteHeight = abs(storedHeight)
            // A cursor DIB normally counts both the color and mask rows in its height.
            let standaloneColor = depth == 32 && expectedHeight == absoluteHeight &&
                colorStride * absoluteHeight <= bytes.count - pixelOffset
            guard standaloneColor || absoluteHeight % 2 == 0 else { throw ParseError.invalidImage }
            let height = standaloneColor ? absoluteHeight : absoluteHeight / 2
            try budget.reserve(width: width, height: height)

            let colorEnd: Int
            let rleIndices: [UInt8]?
            switch encoding {
            case .rle:
                let decoded = try CursorBitmap.decodeRLE(bytes, start: pixelOffset, width: width, height: height, depth: depth)
                let imageSize = Int(bytes.dword(at: 20))
                let declaredEnd = pixelOffset + imageSize
                colorEnd = declaredEnd >= decoded.end && declaredEnd <= bytes.count - maskStride * height
                    ? declaredEnd : decoded.end
                rleIndices = decoded.indices
            case .rgb, .bitFields:
                colorEnd = pixelOffset + colorStride * height
                rleIndices = nil
            }
            guard colorEnd <= bytes.count else { throw ParseError.invalidImage }
            let maskOffset = maskStride * height <= bytes.count - colorEnd ? colorEnd : nil
            guard maskOffset != nil || depth == 32 else { throw ParseError.invalidImage }

            var palette: [Color] = []
            if maxPalette > 0 {
                for entry in 0..<paletteCount {
                    let start = paletteOffset + entry * paletteEntrySize
                    palette.append(Color(red: bytes[start + 2], green: bytes[start + 1], blue: bytes[start]))
                }
            }

            self.bytes = bytes
            self.width = width
            self.height = height
            self.topDown = storedHeight < 0
            self.depth = depth
            self.encoding = encoding
            self.palette = palette
            self.pixelOffset = pixelOffset
            self.maskOffset = maskOffset
            self.colorStride = colorStride
            self.maskStride = maskStride
            self.rleIndices = rleIndices
        }

        func makeImage() throws -> CGImage {
            let useColorAlpha: Bool
            switch encoding {
            case .bitFields(let fields):
                useColorAlpha = fields.alpha != nil
            case .rgb where depth == 32:
                useColorAlpha = (0..<height).contains { row in
                    let offset = pixelOffset + row * colorStride + 3
                    return (0..<width).contains { bytes[offset + $0 * 4] != 0 }
                }
            default:
                useColorAlpha = false
            }

            var rgba = [UInt8](repeating: 0, count: width * height * 4)
            for y in 0..<height {
                let sourceRow = topDown ? y : height - 1 - y
                let row = pixelOffset + sourceRow * colorStride
                for x in 0..<width {
                    var color = try colorAt(x: x, row: row, sourceRow: sourceRow)
                    if !useColorAlpha {
                        let maskByte = maskOffset.map { bytes[$0 + sourceRow * maskStride + x / 8] } ?? 0
                        color.alpha = maskByte & (0x80 >> (x % 8)) == 0 ? 255 : 0
                    }
                    let destination = (y * width + x) * 4
                    let alpha = Int(color.alpha)
                    rgba[destination] = UInt8((Int(color.red) * alpha + 127) / 255)
                    rgba[destination + 1] = UInt8((Int(color.green) * alpha + 127) / 255)
                    rgba[destination + 2] = UInt8((Int(color.blue) * alpha + 127) / 255)
                    rgba[destination + 3] = color.alpha
                }
            }
            guard let provider = CGDataProvider(data: Data(rgba) as CFData),
                  let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                      bytesPerRow: width * 4, space: colorSpace,
                                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                      provider: provider, decode: nil, shouldInterpolate: false,
                                      intent: .defaultIntent) else {
                throw ParseError.invalidImage
            }
            return image
        }

        private func colorAt(x: Int, row: Int, sourceRow: Int) throws -> Color {
            if case .bitFields(let fields) = encoding {
                let value = depth == 16 ? UInt32(bytes.word(at: row + x * 2)) : bytes.dword(at: row + x * 4)
                return fields.color(value)
            }
            if depth == 24 || depth == 32 {
                let offset = row + x * (depth / 8)
                return Color(red: bytes[offset + 2], green: bytes[offset + 1], blue: bytes[offset],
                             alpha: depth == 32 ? bytes[offset + 3] : 255)
            }

            let index: Int
            if let rleIndices {
                index = Int(rleIndices[sourceRow * width + x])
            } else {
                let bitOffset = x * depth
                let shift = 8 - depth - bitOffset % 8
                index = (Int(bytes[row + bitOffset / 8]) >> shift) & ((1 << depth) - 1)
            }
            guard index < palette.count else { throw ParseError.invalidImage }
            return palette[index]
        }
    }

    private static func decodeRLE(
        _ bytes: CursorBytes, start: Int, width: Int, height: Int, depth: Int
    ) throws -> (indices: [UInt8], end: Int) {
        var indices = [UInt8](repeating: 0, count: width * height)
        let end = min(bytes.count, start + 4 * width * height + 4 * height + 4)
        var offset = start
        var x = 0
        var y = 0
        while end - offset >= 2 {
            let count = Int(bytes[offset])
            let value = bytes[offset + 1]
            offset += 2
            if count > 0 {
                guard y < height, count <= width - x else { throw ParseError.invalidImage }
                for i in 0..<count {
                    indices[y * width + x + i] = depth == 8 ? value : nibble(value, index: i)
                }
                x += count
                continue
            }
            switch value {
            case 0:
                guard y < height else { throw ParseError.invalidImage }
                x = 0
                y += 1
            case 1:
                return (indices, offset)
            case 2:
                guard end - offset >= 2 else { throw ParseError.invalidImage }
                x += Int(bytes[offset])
                y += Int(bytes[offset + 1])
                offset += 2
                guard x <= width, y < height else { throw ParseError.invalidImage }
            default:
                let pixels = Int(value)
                let length = depth == 8 ? pixels : (pixels + 1) / 2
                let paddedLength = length + length % 2
                guard y < height, pixels <= width - x, paddedLength <= end - offset else {
                    throw ParseError.invalidImage
                }
                for i in 0..<pixels {
                    indices[y * width + x + i] = depth == 8 ? bytes[offset + i] : nibble(bytes[offset + i / 2], index: i)
                }
                x += pixels
                offset += paddedLength
            }
        }
        throw ParseError.invalidImage
    }

    private static func nibble(_ byte: UInt8, index: Int) -> UInt8 {
        index % 2 == 0 ? byte >> 4 : byte & 0x0F
    }
}
