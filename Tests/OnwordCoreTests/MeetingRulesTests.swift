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

final class MeetingLinkTests: XCTestCase {
    func testFindsLinksInLocationAndNotes() {
        XCTAssertEqual(MeetingLink.find(in: [nil, "https://meet.google.com/abc-defg-hij"])?.platform, .googleMeet)
        let zoom = MeetingLink.find(in: ["Room 4", "Join Zoom Meeting\nhttps://us02web.zoom.us/j/8123456789?pwd=AbC.1 \nMeeting ID: 812"])
        XCTAssertEqual(zoom?.platform, .zoom)
        XCTAssertEqual(zoom?.url.absoluteString, "https://us02web.zoom.us/j/8123456789?pwd=AbC.1")
        XCTAssertEqual(MeetingLink.find(in: ["<https://teams.microsoft.com/l/meetup-join/19%3ameeting_x%40thread.v2/0?context=1>"])?.platform, .teams)
    }

    func testPrefersEarlierFieldsAndIgnoresOtherLinks() {
        XCTAssertNil(MeetingLink.find(in: ["https://docs.google.com/document/d/123", "Office, 3rd floor"]))
        let link = MeetingLink.find(in: ["https://meet.google.com/aaa-bbbb-ccc", "https://zoom.us/j/1"])
        XCTAssertEqual(link?.platform, .googleMeet)
    }

    func testAnyCallAppTakingTheMicIsDetected() {
        XCTAssertEqual(MeetingRules.callApp(bundleID: "us.zoom.xos")?.platform, .zoom)
        XCTAssertEqual(MeetingRules.callApp(bundleID: "com.operasoftware.OperaGX")?.name, "Opera GX")
        XCTAssertEqual(MeetingRules.callApp(bundleID: "com.google.Chrome.helper")?.name, "Chrome")
        XCTAssertEqual(MeetingRules.callApp(bundleID: "com.apple.WebKit.GPU")?.name, "Safari")
        XCTAssertEqual(MeetingRules.callApp(bundleID: "com.tinyspeck.slackmacgap")?.kind, .chat)
        XCTAssertNil(MeetingRules.callApp(bundleID: "com.apple.corespeechd"))
        XCTAssertNil(MeetingRules.callApp(bundleID: "com.apple.QuickTimePlayerX"))
    }

    func testMeetingPagesAndCodes() {
        XCTAssertEqual(MeetingRules.platform(forURL: "https://meet.google.com/abc-defg-hij?authuser=0"), .googleMeet)
        XCTAssertEqual(MeetingRules.platform(forURL: "https://us05web.zoom.us/wc/84512345678/join"), .zoom)
        XCTAssertEqual(MeetingRules.platform(forURL: "https://teams.microsoft.com/l/meetup-join/19%3a"), .teams)
        XCTAssertEqual(MeetingRules.platform(forURL: "https://app.slack.com/huddle/T1/C2"), .slack)
        XCTAssertNil(MeetingRules.platform(forURL: "https://app.slack.com/client/T1/C2"))
        XCTAssertNil(MeetingRules.platform(forURL: "https://www.youtube.com/watch?v=1"))
        XCTAssertEqual(MeetingRules.meetingCode(inURL: "https://meet.google.com/abc-defg-hij"), "abc-defg-hij")
        XCTAssertEqual(MeetingRules.meetingCode(inURL: "https://us05web.zoom.us/j/84512345678?pwd=x"), "84512345678")
        XCTAssertNil(MeetingRules.meetingCode(inURL: "https://meet.google.com/landing"))
    }

    func testOnlyMeetingsStartByThemselves() {
        let chrome = MeetingRules.callApp(bundleID: "com.google.chrome")!, zoom = MeetingRules.callApp(bundleID: "us.zoom.xos")!
        XCTAssertTrue(MeetingRules.mayAutoStart(zoom, pagePlatform: nil, calendarMatched: false))
        XCTAssertTrue(MeetingRules.mayAutoStart(chrome, pagePlatform: .googleMeet, calendarMatched: false))
        XCTAssertFalse(MeetingRules.mayAutoStart(chrome, pagePlatform: nil, calendarMatched: true))
    }

    func testMuteStateFromCallControls() {
        XCTAssertEqual(MeetingRules.muteState(labels: ["Participants", "audio, turn on, currently muted"]), .muted)
        XCTAssertEqual(MeetingRules.muteState(labels: ["audio, turn off, currently unmuted", "Mute"]), .unmuted)
        XCTAssertEqual(MeetingRules.muteState(labels: ["Your camera is on. Your microphone is off."]), .muted)
        XCTAssertEqual(MeetingRules.muteState(labels: ["Turn off microphone (⌘ + d)"]), .unmuted)
        XCTAssertEqual(MeetingRules.muteState(labels: ["Unmute (⌘+Shift+M)"]), .muted)
        XCTAssertEqual(MeetingRules.muteState(labels: ["Mute (⌘+Shift+M)"]), .unmuted)
        // Zoom's own label wins over a "Mute" button next to someone else.
        XCTAssertEqual(MeetingRules.muteState(labels: ["Mute", "audio, turn on, currently muted"]), .muted)
        XCTAssertEqual(MeetingRules.muteState(labels: ["Share screen", "Chat"]), .unknown)
        XCTAssertEqual(MeetingRules.muteState(labels: ["Unmute my microphone"]), .muted)
        XCTAssertEqual(MeetingRules.muteState(labels: ["Mute my microphone"]), .unmuted)
    }
}
