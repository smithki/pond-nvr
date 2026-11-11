import HAP
import Testing
@testable import HAPCamera

@Suite struct StatusSensorTests {
    @Test func aContactSensorClosedUntilSomethingsWrong() throws {
        let sensor = StatusSensor(name: "Pond")
        let service = try #require(sensor.accessory.services.first { $0.type == HAPType.contactSensor })
        #expect(service.primary)
        let state = try #require(service.characteristic(HAPType.contactSensorState))
        let fault = try #require(service.characteristic(HAPType.statusFault))
        #expect(state.value == .int(0) && fault.value == .int(0))
        sensor.set(open: true)
        #expect(state.value == .int(1) && fault.value == .int(1) && sensor.isOpen)
        sensor.set(open: false)
        #expect(state.value == .int(0) && !sensor.isOpen)
    }

    @Test func itsFirmwareIsNumbersOnly() {
        #expect(StatusSensor.firmware("0.2.1-dev") == "0.2.1")
        #expect(StatusSensor.firmware("dev") == "1.0.0")
    }
}
