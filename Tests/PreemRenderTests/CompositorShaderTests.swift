import XCTest
import PreemCore
@testable import PreemRender

/// Guards that the compositor's Metal shader source (which now includes the
/// color-management + grade path) actually compiles. The shader is built in
/// `OfflineSequenceCompositor.init` via `device.makeLibrary(source:)`, so a
/// successful init means the MSL is valid and all pipeline functions linked.
final class CompositorShaderTests: XCTestCase {
    func testCompositorInitCompilesShader() throws {
        guard PreemRender.device != nil else {
            throw XCTSkip("No Metal device in this environment")
        }
        let settings = SequenceSettings(frameRate: .twentyFour,
                                        resolution: PixelSize(width: 1920, height: 1080))
        let sequence = Sequence(name: "Test", settings: settings)
        XCTAssertNoThrow(try OfflineSequenceCompositor(sequence: sequence, mediaPool: MediaPool()))
    }
}
