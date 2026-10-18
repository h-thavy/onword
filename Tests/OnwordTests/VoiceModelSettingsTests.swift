import Foundation
import XCTest
@testable import Onword

final class VoiceModelSettingsTests: XCTestCase {
    func testPendingDownloadShowsItsSizeAndRequiresManualRetry() async {
        await MainActor.run {
            let message = DictationController.describeModelError(URLError(.notConnectedToInternet), online: false,
                                                                model: .baseEnglish, retriesAutomatically: false)
            XCTAssertTrue(message.contains("about 150 MB"))
            XCTAssertTrue(message.contains("Click Try again"))
            XCTAssertFalse(message.contains("It’ll retry"))
        }
    }

    func testSelectedModelFailureDescribesAutomaticRetry() async {
        await MainActor.run {
            let message = DictationController.describeModelError(URLError(.notConnectedToInternet), online: false,
                                                                model: .largeTurbo)
            XCTAssertTrue(message.contains("about 630 MB"))
            XCTAssertTrue(message.contains("It’ll retry"))
        }
    }

    func testPendingGenericFailureDoesNotClaimAutomaticRetries() async {
        await MainActor.run {
            let message = DictationController.describeModelError(URLError(.badServerResponse), online: true,
                                                                retriesAutomatically: false)
            XCTAssertTrue(message.contains("Click Try again"))
            XCTAssertFalse(message.contains("retrying on its own"))
        }
    }
}
