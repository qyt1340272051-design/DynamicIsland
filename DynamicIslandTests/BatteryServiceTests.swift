import Foundation
import IOKit.ps
import XCTest
@testable import DynamicIsland

final class BatteryServiceTests: XCTestCase {
    func testParsesInternalBatteryCapacityAndChargingState() throws {
        let description: NSDictionary = [
            kIOPSTypeKey: kIOPSInternalBatteryType,
            kIOPSCurrentCapacityKey: NSNumber(value: 63),
            kIOPSMaxCapacityKey: NSNumber(value: 100),
            kIOPSPowerSourceStateKey: kIOPSACPowerValue,
            kIOPSIsChargingKey: NSNumber(value: true),
            kIOPSIsChargedKey: NSNumber(value: false)
        ]

        let state = try XCTUnwrap(IOKitBatteryService.parseInternalBattery(description))

        XCTAssertEqual(state.level, 0.63, accuracy: 0.000_1)
        XCTAssertEqual(state.powerSource, .ac)
        XCTAssertTrue(state.isCharging)
        XCTAssertFalse(state.isCharged)
    }

    func testParserIgnoresNonInternalOrInvalidPowerSources() {
        let ups: NSDictionary = [
            kIOPSTypeKey: kIOPSUPSType,
            kIOPSCurrentCapacityKey: NSNumber(value: 50),
            kIOPSMaxCapacityKey: NSNumber(value: 100),
            kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue
        ]
        let invalidMaximum: NSDictionary = [
            kIOPSTypeKey: kIOPSInternalBatteryType,
            kIOPSCurrentCapacityKey: NSNumber(value: 50),
            kIOPSMaxCapacityKey: NSNumber(value: 0),
            kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue
        ]
        let unknownPowerSource: NSDictionary = [
            kIOPSTypeKey: kIOPSInternalBatteryType,
            kIOPSCurrentCapacityKey: NSNumber(value: 50),
            kIOPSMaxCapacityKey: NSNumber(value: 100),
            kIOPSPowerSourceStateKey: "Unknown"
        ]

        XCTAssertNil(IOKitBatteryService.parseInternalBattery(ups))
        XCTAssertNil(IOKitBatteryService.parseInternalBattery(invalidMaximum))
        XCTAssertNil(IOKitBatteryService.parseInternalBattery(unknownPowerSource))
    }

    func testBatteryStateNormalizesNonFiniteAndOutOfRangeLevels() {
        XCTAssertEqual(BatteryState(level: -.infinity, powerSource: .battery, isCharging: false, isCharged: false).level, 0)
        XCTAssertEqual(BatteryState(level: -0.2, powerSource: .battery, isCharging: false, isCharged: false).level, 0)
        XCTAssertEqual(BatteryState(level: 1.2, powerSource: .ac, isCharging: false, isCharged: true).level, 1)
    }

    func testLiveServiceReturnsNoBatteryOrBoundedInternalBattery() throws {
        if let state = try IOKitBatteryService().currentState() {
            XCTAssertGreaterThanOrEqual(state.level, 0)
            XCTAssertLessThanOrEqual(state.level, 1)
        }
    }
}
