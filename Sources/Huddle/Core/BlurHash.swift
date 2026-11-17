import CoreGraphics
import Foundation

/// BlurHash: a couple of dozen characters that stand for a blurred version of an image. Matrix
/// clients send one with each picture so there is something to show while the real one loads.
///
/// The format is a handful of cosine-wave strengths (how much of each broad stripe of colour the
/// image has), written in base 83.
enum BlurHash {
    // MARK: Decoding

    /// The blur a hash stands for, as a small image to be scaled up. Nil if the hash is malformed.
    static func image(from hash: String, width: Int = 32, height: Int = 32) -> CGImage? {
        let characters = Array(hash)
        guard characters.count >= 6, let sizeFlag = decode(characters[0..<1]),
              let quantisedMaximum = decode(characters[1..<2]) else { return nil }
        let componentsX = sizeFlag % 9 + 1
        let componentsY = sizeFlag / 9 + 1
        guard characters.count == 4 + 2 * componentsX * componentsY else { return nil }
        let maximum = Float(quantisedMaximum + 1) / 166

        var colours: [(Float, Float, Float)] = []
        for index in 0..<componentsX * componentsY {
            if index == 0 {
                guard let value = decode(characters[2..<6]) else { return nil }
                colours.append((linear(value >> 16), linear((value >> 8) & 255), linear(value & 255)))
            } else {
                guard let value = decode(characters[4 + index * 2..<6 + index * 2]) else { return nil }
                func strength(_ quantised: Int) -> Float { signedPower((Float(quantised) - 9) / 9, 2) * maximum }
                colours.append((strength(value / 361), strength(value / 19 % 19), strength(value % 19)))
            }
        }

        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                var (r, g, b): (Float, Float, Float) = (0, 0, 0)
                for j in 0..<componentsY {
                    for i in 0..<componentsX {
                        let basis = cos(.pi * Float(x) * Float(i) / Float(width)) * cos(.pi * Float(y) * Float(j) / Float(height))
                        let colour = colours[i + j * componentsX]
                        r += colour.0 * basis
                        g += colour.1 * basis
                        b += colour.2 * basis
                    }
                }
                let offset = (y * width + x) * 4
                pixels[offset] = UInt8(sRGB(r))
                pixels[offset + 1] = UInt8(sRGB(g))
                pixels[offset + 2] = UInt8(sRGB(b))
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: Encoding

    /// The hash for an image. Give it a small one (a few dozen pixels across): the result barely
    /// changes with more, and the work grows with every pixel.
    static func hash(for image: CGImage, componentsX: Int = 4, componentsY: Int = 3) -> String? {
        let (width, height) = (image.width, image.height)
        guard width > 0, height > 0, (1...9).contains(componentsX), (1...9).contains(componentsY) else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var factors: [(Float, Float, Float)] = []
        for j in 0..<componentsY {
            for i in 0..<componentsX {
                var (r, g, b): (Float, Float, Float) = (0, 0, 0)
                for y in 0..<height {
                    for x in 0..<width {
                        let basis = cos(.pi * Float(i) * Float(x) / Float(width)) * cos(.pi * Float(j) * Float(y) / Float(height))
                        let offset = (y * width + x) * 4
                        r += basis * linear(Int(pixels[offset]))
                        g += basis * linear(Int(pixels[offset + 1]))
                        b += basis * linear(Int(pixels[offset + 2]))
                    }
                }
                let scale = (i == 0 && j == 0 ? 1 : 2) / Float(width * height)
                factors.append((r * scale, g * scale, b * scale))
            }
        }

        var hash = encode(componentsX - 1 + (componentsY - 1) * 9, length: 1)
        let waves = factors.dropFirst()
        let maximum: Float
        if let largest = waves.map({ max(abs($0.0), abs($0.1), abs($0.2)) }).max() {
            let quantised = max(0, min(82, Int((largest * 166 - 0.5).rounded(.down))))
            maximum = Float(quantised + 1) / 166
            hash += encode(quantised, length: 1)
        } else {
            maximum = 1
            hash += encode(0, length: 1)
        }
        let average = factors[0]
        hash += encode(sRGB(average.0) << 16 + sRGB(average.1) << 8 + sRGB(average.2), length: 4)
        for wave in waves {
            func quantise(_ value: Float) -> Int {
                max(0, min(18, Int((signedPower(value / maximum, 0.5) * 9 + 9.5).rounded(.down))))
            }
            hash += encode(quantise(wave.0) * 361 + quantise(wave.1) * 19 + quantise(wave.2), length: 2)
        }
        return hash
    }

    // MARK: Pieces

    private static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~")
    private static let values: [Character: Int] = Dictionary(uniqueKeysWithValues: alphabet.enumerated().map { ($1, $0) })

    private static func decode(_ characters: ArraySlice<Character>) -> Int? {
        var value = 0
        for character in characters {
            guard let digit = values[character] else { return nil }
            value = value * 83 + digit
        }
        return value
    }

    private static func encode(_ value: Int, length: Int) -> String {
        var (remaining, result) = (value, "")
        for _ in 0..<length {
            result = String(alphabet[remaining % 83]) + result
            remaining /= 83
        }
        return result
    }

    /// A stored colour value (0…255) as an amount of light (0…1).
    private static func linear(_ value: Int) -> Float {
        let v = Float(value) / 255
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    /// An amount of light as a stored colour value.
    private static func sRGB(_ value: Float) -> Int {
        let v = max(0, min(1, value))
        return Int((v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055) * 255 + 0.5)
    }

    private static func signedPower(_ value: Float, _ exponent: Float) -> Float {
        copysign(pow(abs(value), exponent), value)
    }
}
