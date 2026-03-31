import Foundation

/// An image to include in a prompt sent to Claude.
public struct ImageAttachment: Sendable {

    /// Raw image data.
    public var data: Data

    /// MIME type of the image.
    public var mediaType: MediaType

    public init(data: Data, mediaType: MediaType) {
        self.data = data
        self.mediaType = mediaType
    }

    public enum MediaType: String, Sendable {
        case jpeg = "image/jpeg"
        case png = "image/png"
        case gif = "image/gif"
        case webp = "image/webp"
    }
}
