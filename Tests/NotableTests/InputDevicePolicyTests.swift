import XCTest

/// Spec 23: which microphone a recording opens. Every rule, every exception —
/// a wrong choice here is a meeting without the local user's voice.
final class InputDevicePolicyTests: XCTestCase {
    private let builtIn = AudioDeviceInfo(id: 80, uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone",
                                          transport: .builtIn, isRunningSomewhere: false)
    private let usb = AudioDeviceInfo(id: 90, uid: "usb-1", name: "Yeti", transport: .wired, isRunningSomewhere: false)
    private let airPods = AudioDeviceInfo(id: 91, uid: "bt-1", name: "AirPods Pro", transport: .bluetooth, isRunningSomewhere: true)
    private let idleAirPods = AudioDeviceInfo(id: 92, uid: "bt-2", name: "AirPods Max", transport: .bluetooth, isRunningSomewhere: false)
    private let iPhone = AudioDeviceInfo(id: 95, uid: "cc-1", name: "iPhone Microphone", transport: .continuity, isRunningSomewhere: true)
    private let idleIPhone = AudioDeviceInfo(id: 96, uid: "cc-2", name: "iPhone Microphone", transport: .continuity, isRunningSomewhere: false)
    private let teamsAudio = AudioDeviceInfo(id: 85, uid: "MSLoopbackDriverDevice_UID", name: "Microsoft Teams Audio",
                                             transport: .virtual, isRunningSomewhere: true)

    private func context(
        _ devices: [AudioDeviceInfo], default defaultID: UInt32? = 80, pinned: String? = nil,
        call: [UInt32] = [], lidClosed: Bool = false, dictation: Bool = false
    ) -> InputDevicePolicy.Context {
        InputDevicePolicy.Context(devices: devices, defaultInputID: defaultID, pinnedUID: pinned,
                                  callDeviceIDs: call, lidClosed: lidClosed, allowIdleWireless: dictation)
    }

    // MARK: - Rule 3: the default, as long as it can hear anything

    func testLidOpenKeepsTheSystemDefault() {
        let choice = InputDevicePolicy.choose(context([builtIn, usb, airPods]))
        XCTAssertEqual(choice.device, builtIn)
        XCTAssertEqual(choice.reason, .systemDefault)
        XCTAssertFalse(choice.isKnownSilent)
    }

    /// The measured case: lid shut, the built-in mic still the default, and a
    /// month of calls recorded as 0.0.
    func testLidClosedSkipsTheBuiltInDefault() {
        let choice = InputDevicePolicy.choose(context([builtIn, iPhone, airPods, usb], lidClosed: true))
        XCTAssertEqual(choice.device, usb, "Kabel vor Bluetooth vor Continuity")
        XCTAssertEqual(choice.reason, .fallback)
    }

    func testRunningBluetoothBeatsContinuity() {
        let choice = InputDevicePolicy.choose(context([builtIn, iPhone, airPods], lidClosed: true))
        XCTAssertEqual(choice.device, airPods)
    }

    func testAnExternalDefaultIsUsedWithTheLidClosed() {
        let choice = InputDevicePolicy.choose(context([builtIn, usb], default: 90, lidClosed: true))
        XCTAssertEqual(choice.device, usb)
        XCTAssertEqual(choice.reason, .systemDefault)
    }

    // MARK: - Rule 4: idle wireless devices are not opened for a meeting

    /// Opening an AirPods mic the call does not use switches them to headset mode.
    func testIdleBluetoothIsNotOpenedForAMeeting() {
        let choice = InputDevicePolicy.choose(context([builtIn, idleAirPods, idleIPhone], lidClosed: true))
        XCTAssertEqual(choice.device, builtIn)
        XCTAssertEqual(choice.reason, .lidClosedNoAlternative)
        XCTAssertTrue(choice.isKnownSilent, "sofort warnen, nicht nach 20 s")
    }

    /// Dictation was asked for by a key press, and the alternative is zeros.
    func testDictationMayOpenAnIdleHeadsetWhenTheAlternativeIsSilence() {
        let choice = InputDevicePolicy.choose(context([builtIn, idleIPhone, idleAirPods], lidClosed: true, dictation: true))
        XCTAssertEqual(choice.device, idleAirPods)
        XCTAssertEqual(choice.reason, .fallback)
    }

    func testDictationWithTheLidOpenDoesNotTouchTheHeadset() {
        let choice = InputDevicePolicy.choose(context([builtIn, idleAirPods], dictation: true))
        XCTAssertEqual(choice.device, builtIn)
    }

    func testVirtualDevicesAreNeverAFallback() {
        let choice = InputDevicePolicy.choose(context([builtIn, teamsAudio], lidClosed: true))
        XCTAssertEqual(choice.device, builtIn)
        XCTAssertTrue(choice.isKnownSilent)
    }

    // MARK: - Rule 2: the call's own device

    func testMeetingFollowsTheCallDevice() {
        let choice = InputDevicePolicy.choose(context([builtIn, airPods, usb], call: [91]))
        XCTAssertEqual(choice.device, airPods)
        XCTAssertEqual(choice.reason, .followsCall)
    }

    /// "Microsoft Teams Audio" is the call's loopback driver, not a microphone.
    func testACallOnAVirtualDeviceIsIgnored() {
        let choice = InputDevicePolicy.choose(context([builtIn, teamsAudio, usb], call: [85]))
        XCTAssertEqual(choice.device, builtIn)
        XCTAssertEqual(choice.reason, .systemDefault)
    }

    func testACallOnTheLidClosedBuiltInIsNotFollowed() {
        let choice = InputDevicePolicy.choose(context([builtIn, airPods], call: [80], lidClosed: true))
        XCTAssertEqual(choice.device, airPods)
    }

    // MARK: - Rule 1: the pin

    func testPinnedDeviceWins() {
        let choice = InputDevicePolicy.choose(context([builtIn, airPods, usb], pinned: "usb-1", call: [91]))
        XCTAssertEqual(choice.device, usb)
        XCTAssertEqual(choice.reason, .pinned)
    }

    func testUnpluggedPinFallsThroughToTheOtherRules() {
        let choice = InputDevicePolicy.choose(context([builtIn, airPods], pinned: "usb-1", call: [91]))
        XCTAssertEqual(choice.device, airPods)
        XCTAssertEqual(choice.reason, .followsCall)
    }

    func testPinnedBuiltInBehindAClosedLidCountsAsUnplugged() {
        let choice = InputDevicePolicy.choose(context([builtIn, usb], pinned: "BuiltInMicrophoneDevice", lidClosed: true))
        XCTAssertEqual(choice.device, usb)
    }

    func testNoDevicesAtAll() {
        let choice = InputDevicePolicy.choose(context([], default: nil))
        XCTAssertNil(choice.device)
        XCTAssertEqual(choice.reason, .noDevice)
    }

    // MARK: - Switching while recording

    private func shouldSwitch(
        from current: (UInt32, InputDevicePolicy.Reason)?, _ context: InputDevicePolicy.Context
    ) -> Bool {
        InputDevicePolicy.shouldSwitch(
            from: current.map { (id: $0.0, reason: $0.1) },
            to: InputDevicePolicy.choose(context), in: context
        )
    }

    func testUnpluggedDeviceIsReplaced() {
        XCTAssertTrue(shouldSwitch(from: (90, .pinned), context([builtIn, airPods])))
    }

    func testTheCallChangingItsDeviceIsFollowed() {
        XCTAssertTrue(shouldSwitch(from: (91, .followsCall), context([builtIn, airPods, usb], call: [90])))
    }

    /// A muted participant can release the mic; that is not a reason to leave
    /// the headset they are talking into.
    func testTheCallGoingQuietDoesNotMoveTheCapture() {
        XCTAssertFalse(shouldSwitch(from: (91, .followsCall), context([builtIn, airPods])))
    }

    func testADefaultChangeIsFollowedOnlyWhenFollowingTheDefault() {
        XCTAssertTrue(shouldSwitch(from: (80, .systemDefault), context([builtIn, usb], default: 90)))
        XCTAssertFalse(shouldSwitch(from: (91, .fallback), context([builtIn, airPods, usb], default: 90)))
    }

    func testHeadsetArrivingRescuesAKnownSilentCapture() {
        XCTAssertTrue(shouldSwitch(from: (80, .lidClosedNoAlternative), context([builtIn, airPods], lidClosed: true)))
    }

    func testKnownSilentWithNothingBetterStays() {
        XCTAssertFalse(shouldSwitch(from: (80, .lidClosedNoAlternative), context([builtIn, idleAirPods], lidClosed: true)))
    }

    func testTheSameDeviceIsNeverASwitch() {
        XCTAssertFalse(shouldSwitch(from: (91, .followsCall), context([builtIn, airPods], call: [91])))
    }
}
