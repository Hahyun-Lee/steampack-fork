import XCTest
@testable import SteamPack

final class PowerSafetyTests: XCTestCase {
    func testLowBatteryOnBatteryDisarmsAtThreshold() {
        let snapshot = PowerSafetySnapshot(
            batteryPercent: 20,
            powerConnection: .battery,
            thermalState: .nominal
        )
        XCTAssertEqual(PowerSafetyPolicy.issue(for: snapshot), .lowBattery(percent: 20))
    }

    func testLowBatteryDoesNotDisarmOnACPower() {
        let snapshot = PowerSafetySnapshot(
            batteryPercent: 5,
            powerConnection: .acPower,
            thermalState: .nominal
        )
        XCTAssertNil(PowerSafetyPolicy.issue(for: snapshot))
    }

    func testSeriousThermalStateAlwaysDisarms() {
        let snapshot = PowerSafetySnapshot(
            batteryPercent: 100,
            powerConnection: .acPower,
            thermalState: .serious
        )
        XCTAssertEqual(PowerSafetyPolicy.issue(for: snapshot), .highTemperature)
    }

    func testFairThermalStateIsAllowed() {
        let snapshot = PowerSafetySnapshot(
            batteryPercent: 80,
            powerConnection: .battery,
            thermalState: .fair
        )
        XCTAssertNil(PowerSafetyPolicy.issue(for: snapshot))
    }

    func testUnknownPowerSourceIsUnsafe() {
        let snapshot = PowerSafetySnapshot(
            batteryPercent: 80,
            powerConnection: .unknown,
            thermalState: .nominal
        )

        XCTAssertEqual(
            PowerSafetyPolicy.issue(for: snapshot),
            .powerSourceUnavailable
        )
    }

    func testMissingBatteryCapacityIsUnsafeWhileUnplugged() {
        let snapshot = PowerSafetySnapshot(
            batteryPercent: nil,
            powerConnection: .battery,
            thermalState: .nominal
        )

        XCTAssertEqual(
            PowerSafetyPolicy.issue(for: snapshot),
            .batteryLevelUnavailable
        )
    }

    func testMissingBatteryCapacityRemainsAllowedOnConfirmedACPower() {
        let snapshot = PowerSafetySnapshot(
            batteryPercent: nil,
            powerConnection: .acPower,
            thermalState: .nominal
        )

        XCTAssertNil(PowerSafetyPolicy.issue(for: snapshot))
    }
}
