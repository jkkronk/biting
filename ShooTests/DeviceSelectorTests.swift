import XCTest
@testable import Shoo

/// ``DeviceSelector/rank`` preference order over the pure ``CameraDescriptor`` core:
/// remembered device → system default → built-in wide-angle → first available, with
/// desk-view cameras skipped unless nothing else exists.
final class DeviceSelectorTests: XCTestCase {
    private func cam(
        _ id: String, deskView: Bool = false, builtIn: Bool = false
    ) -> DeviceSelector.CameraDescriptor {
        .init(uniqueID: id, isDeskView: deskView, isBuiltInWideAngle: builtIn)
    }

    func testEmptyYieldsNil() {
        XCTAssertNil(DeviceSelector.rank(preferredID: "x", systemDefaultID: "y", devices: []))
    }

    func testRememberedDeviceWins() {
        let devices = [cam("built-in", builtIn: true), cam("external")]
        let pick = DeviceSelector.rank(
            preferredID: "external", systemDefaultID: "built-in", devices: devices)
        XCTAssertEqual(pick?.uniqueID, "external")
    }

    func testSystemDefaultWhenRememberedAbsent() {
        let devices = [cam("built-in", builtIn: true), cam("external")]
        let pick = DeviceSelector.rank(
            preferredID: "unplugged", systemDefaultID: "external", devices: devices)
        XCTAssertEqual(pick?.uniqueID, "external")
    }

    func testBuiltInWhenNoRememberedOrSystemMatch() {
        let devices = [cam("external"), cam("built-in", builtIn: true)]
        let pick = DeviceSelector.rank(preferredID: nil, systemDefaultID: nil, devices: devices)
        XCTAssertEqual(pick?.uniqueID, "built-in")
    }

    func testFirstAvailableFallback() {
        let devices = [cam("external-a"), cam("external-b")]
        let pick = DeviceSelector.rank(preferredID: nil, systemDefaultID: nil, devices: devices)
        XCTAssertEqual(pick?.uniqueID, "external-a")
    }

    func testDeskViewSkippedWhenAlternativesExist() {
        let devices = [cam("desk", deskView: true), cam("external")]
        // Even as the remembered *and* system default device, desk view loses to a usable cam.
        let pick = DeviceSelector.rank(
            preferredID: "desk", systemDefaultID: "desk", devices: devices)
        XCTAssertEqual(pick?.uniqueID, "external")
    }

    func testDeskViewUsedWhenOnlyDevice() {
        let devices = [cam("desk", deskView: true)]
        let pick = DeviceSelector.rank(preferredID: nil, systemDefaultID: nil, devices: devices)
        XCTAssertEqual(pick?.uniqueID, "desk")
    }
}
