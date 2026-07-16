import XCTest
@testable import SteamPack

final class PowerSafetyTests: XCTestCase {
    func testLowBatteryOnBatteryDisarmsAtThreshold() {
        let snapshot = PowerSafetySnapshot(
            batteryPercent: 20,
            isOnACPower: false,
            thermalState: .nominal
        )
        XCTAssertEqual(PowerSafetyPolicy.issue(for: snapshot), .lowBattery(percent: 20))
    }

    func testLowBatteryDoesNotDisarmOnACPower() {
        let snapshot = PowerSafetySnapshot(
            batteryPercent: 5,
            isOnACPower: true,
            thermalState: .nominal
        )
        XCTAssertNil(PowerSafetyPolicy.issue(for: snapshot))
    }

    func testSeriousThermalStateAlwaysDisarms() {
        let snapshot = PowerSafetySnapshot(
            batteryPercent: 100,
            isOnACPower: true,
            thermalState: .serious
        )
        XCTAssertEqual(PowerSafetyPolicy.issue(for: snapshot), .highTemperature)
    }

    func testFairThermalStateIsAllowed() {
        let snapshot = PowerSafetySnapshot(
            batteryPercent: 80,
            isOnACPower: false,
            thermalState: .fair
        )
        XCTAssertNil(PowerSafetyPolicy.issue(for: snapshot))
    }
}
