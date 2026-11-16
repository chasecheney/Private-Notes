import Foundation
import ImageIO

enum ImageImport {
    /// Returns the image with its GPS location removed, or nil if the data is not an image.
    /// The picture is re-saved in its original format; other details (camera, date) are kept.
    static func strippingLocation(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source)
        else { return nil }

        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type, count, nil) else { return nil }

        let withoutLocation = [kCGImagePropertyGPSDictionary: kCFNull as Any] as CFDictionary
        for index in 0..<count {
            CGImageDestinationAddImageFromSource(destination, source, index, withoutLocation)
        }
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
