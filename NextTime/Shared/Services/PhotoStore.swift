import UIKit

/// Saves photos for places as JPEG files in the shared container.
enum PhotoStore {
    /// Big enough to read a menu, small enough to keep dozens of places light.
    private static let maxPixelSize: CGFloat = 2048

    static var directory: URL {
        AppGroup.containerURL.appending(path: "Photos", directoryHint: .isDirectory)
    }

    static func url(for name: String) -> URL {
        directory.appending(path: name)
    }

    /// Stores the image and returns its file name.
    static func save(_ image: UIImage) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = resized(image).jpegData(compressionQuality: 0.8) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let name = UUID().uuidString + ".jpg"
        try data.write(to: url(for: name), options: .atomic)
        return name
    }

    static func save(data: Data) throws -> String {
        guard let image = UIImage(data: data) else { throw CocoaError(.fileReadCorruptFile) }
        return try save(image)
    }

    static func image(named name: String) -> UIImage? {
        UIImage(contentsOfFile: url(for: name).path)
    }

    static func thumbnail(named name: String, side: CGFloat) async -> UIImage? {
        await image(named: name)?.byPreparingThumbnail(ofSize: CGSize(width: side, height: side))
    }

    static func delete(_ names: [String]) {
        for name in names {
            try? FileManager.default.removeItem(at: url(for: name))
        }
    }

    private static func resized(_ image: UIImage) -> UIImage {
        let longest = max(image.size.width, image.size.height) * image.scale
        guard longest > maxPixelSize else { return image }
        let factor = maxPixelSize / longest
        let size = CGSize(width: image.size.width * image.scale * factor,
                          height: image.size.height * image.scale * factor)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
