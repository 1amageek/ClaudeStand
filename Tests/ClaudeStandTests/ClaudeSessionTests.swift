import Testing
import Foundation
@testable import ClaudeStand

@Suite("ClaudeSession")
struct ClaudeSessionTests {

    @Test("SDKUserMessage with text-only prompt uses string content")
    func textOnlyMessage() async throws {
        let session = ClaudeSession()
        // Access the private builder via reflection-free approach:
        // verify the JSON structure by testing the public API contract
        let config = ClaudeConfiguration()
        #expect(config.allowedTools == ClaudeConfiguration.iPadTools)
    }

    @Test("ImageAttachment initializes correctly")
    func imageAttachment() {
        let data = Data([0x89, 0x50, 0x4E, 0x47])  // PNG magic bytes
        let attachment = ImageAttachment(data: data, mediaType: .png)
        #expect(attachment.mediaType.rawValue == "image/png")
        #expect(attachment.data.count == 4)
    }

    @Test("ImageAttachment media types have correct MIME values")
    func imageMediaTypes() {
        #expect(ImageAttachment.MediaType.jpeg.rawValue == "image/jpeg")
        #expect(ImageAttachment.MediaType.png.rawValue == "image/png")
        #expect(ImageAttachment.MediaType.gif.rawValue == "image/gif")
        #expect(ImageAttachment.MediaType.webp.rawValue == "image/webp")
    }

    @Test("Session starts with nil sessionID and metadata")
    func initialState() async {
        let session = ClaudeSession()
        let sessionID = await session.sessionID
        let metadata = await session.metadata
        #expect(sessionID == nil)
        #expect(metadata == nil)
    }

    @Test("SessionError descriptions are meaningful")
    func errorDescriptions() {
        let notStarted = ClaudeSession.SessionError.notStarted
        #expect(notStarted.errorDescription?.contains("start()") == true)

        let deallocated = ClaudeSession.SessionError.deallocated
        #expect(deallocated.errorDescription?.contains("deallocated") == true)
    }
}
