import XCTest
@testable import OnwordCore

final class MeetingRulesTests: XCTestCase {
    func testNativeAppsCountOnTheirOwn() {
        XCTAssertEqual(MeetingRules.platform(bundleID: "us.zoom.xos", windowTitles: []), .zoom)
        XCTAssertEqual(MeetingRules.platform(bundleID: "com.microsoft.teams2", windowTitles: []), .teams)
    }

    func testBrowsersNeedACallWindow() {
        XCTAssertNil(MeetingRules.platform(bundleID: "com.google.Chrome", windowTitles: ["YouTube"]))
        XCTAssertEqual(MeetingRules.platform(bundleID: "com.google.Chrome", windowTitles: ["Inbox", "Meet - abc-defg-hij"]), .googleMeet)
        XCTAssertEqual(MeetingRules.platform(bundleID: "com.apple.Safari", windowTitles: ["Chat | Microsoft Teams"]), .teams)
    }

    func testSlackNeedsAHuddle() {
        XCTAssertNil(MeetingRules.platform(bundleID: "com.tinyspeck.slackmacgap", windowTitles: ["general - Acme - Slack"]))
        XCTAssertEqual(MeetingRules.platform(bundleID: "com.tinyspeck.slackmacgap", windowTitles: ["Huddle: #design"]), .slack)
    }

    func testUnknownAppsAreIgnored() {
        XCTAssertNil(MeetingRules.platform(bundleID: "com.apple.QuickTimePlayerX", windowTitles: ["Meet - abc"]))
    }
}

final class SpeakerNamesTests: XCTestCase {
    func testClean() {
        XCTAssertEqual(SpeakerNames.clean("Dara Sok (Host)"), "Dara Sok")
        XCTAssertEqual(SpeakerNames.clean(" Sam, active speaker "), "Sam")
        XCTAssertEqual(SpeakerNames.clean("Lina Chea, Organizer"), "Lina Chea")
        XCTAssertTrue(SpeakerNames.isSelf("You"))
        XCTAssertFalse(SpeakerNames.isPlausible("12:04"))
        XCTAssertFalse(SpeakerNames.isPlausible("Mute"))
    }

    func seg(_ start: Double, _ end: Double, _ speaker: String) -> TranscriptSegment {
        TranscriptSegment(start: start, end: end, speaker: speaker, text: "…")
    }

    func obs(_ t: Double, _ names: String...) -> SpeakerObservation { SpeakerObservation(t: t, speaking: names) }

    func testAssignsNamesByVotes() {
        let segments = [seg(0, 4, "s1"), seg(5, 9, "s2"), seg(10, 13, "s1"), seg(14, 16, "me")]
        let observations = [
            obs(0.5, "Samantha"), obs(1.5, "Samantha"), obs(2.5, "Samantha"), obs(3.5, "Samantha (Host)"),
            obs(5.5, "Daniel"), obs(6.5, "Daniel"), obs(7.5, "Daniel"),
            obs(11, "Samantha"),
            obs(14.5, "You"), obs(15, "You"), obs(15.5, "You"),
        ]
        XCTAssertEqual(SpeakerNames.assign(segments: segments, observations: observations), ["s1": "Samantha", "s2": "Daniel"])
    }

    func testNeedsEnoughAgreeingVotes() {
        let segments = [seg(0, 10, "s1")]
        // Only two votes → not enough.
        XCTAssertTrue(SpeakerNames.assign(segments: segments, observations: [obs(1, "Ana"), obs(2, "Ana")]).isEmpty)
        // Split votes → no clear winner.
        let split = [obs(1, "Ana"), obs(2, "Ana"), obs(3, "Ana"), obs(4, "Bo"), obs(5, "Bo"), obs(6, "Bo")]
        XCTAssertTrue(SpeakerNames.assign(segments: segments, observations: split).isEmpty)
    }

    func testIgnoresMomentsWithSeveralPeopleSpeaking() {
        let segments = [seg(0, 10, "s1")]
        let observations = [obs(1, "Ana", "Bo"), obs(2, "Ana", "Bo"), obs(3, "Ana", "Bo"), obs(4, "Ana")]
        XCTAssertTrue(SpeakerNames.assign(segments: segments, observations: observations).isEmpty)
    }
}

final class ActionItemCheckTests: XCTestCase {
    let lines = [
        ActionItemCheck.Line(speaker: "Samantha Lee", text: "Good morning everyone, let's go through the sprint review for the mobile app."),
        ActionItemCheck.Line(speaker: "Daniel Kim", text: "The payment screen is done and the QA team approved it yesterday."),
        ActionItemCheck.Line(speaker: "Samantha Lee", text: "Great, are there any blockers before the release on Tuesday?"),
        ActionItemCheck.Line(speaker: "Daniel Kim", text: "Only the app store screenshots, I will finish them by Monday."),
        ActionItemCheck.Line(speaker: "Samantha Lee", text: "Dara, can you send the release notes to marketing?"),
    ]

    func testKeepsRealCommitment() {
        XCTAssertTrue(ActionItemCheck.isGrounded(quote: "I will finish them by Monday", owner: "Daniel Kim", lines: lines))
    }

    func testKeepsTaskAssignedByName() {
        XCTAssertTrue(ActionItemCheck.isGrounded(quote: "can you send the release notes to marketing", owner: "Dara", lines: lines))
    }

    func testRejectsInventedTasks() {
        // Quote exists but isn't a commitment.
        XCTAssertFalse(ActionItemCheck.isGrounded(quote: "let's go through the sprint review", owner: "Samantha Lee", lines: lines))
        // Quote doesn't exist.
        XCTAssertFalse(ActionItemCheck.isGrounded(quote: "I will plan the next sprint", owner: "Daniel Kim", lines: lines))
        // Real commitment, wrong owner.
        XCTAssertFalse(ActionItemCheck.isGrounded(quote: "I will finish them by Monday", owner: "Samantha Lee", lines: lines))
    }
}
