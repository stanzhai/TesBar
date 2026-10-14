import Foundation
import Testing

@testable import TesBar

/// Canonical JSON shape ticket 05 emits after mapping the Fleet API response.
/// Proves the module compiles, the value types are decodable, and commands carry payloads.
@Test func snapshotDecodesAndCommandsCarryPayloads() throws {
    let json = """
        {"id":"123","name":"My Tesla","charge":{"batteryPercent":77,"rangeKm":238.6,"state":"Charging","minutesToFull":45},
         "climate":{"insideC":21.5,"outsideC":8.0},"doors":{"locked":true,"frontTrunkOpen":false,"rearTrunkOpen":true},
         "odometerKm":12834.2,"state":"online","timestampMs":1760000000000}
        """
    let snapshot = try JSONDecoder().decode(VehicleSnapshot.self, from: Data(json.utf8))
    #expect(snapshot.charge.batteryPercent == 77)
    #expect(snapshot.charge.minutesToFull == 45)
    #expect(snapshot.climate.outsideC == 8.0)
    #expect(snapshot.doors.rearTrunkOpen)
    #expect(snapshot.state == .online)
    #expect(snapshot.timestampMs == 1_760_000_000_000)

    let entry = try JSONDecoder().decode(VehicleListEntry.self, from: Data(#"{"id":"123","name":"My Tesla"}"#.utf8))
    #expect(entry == VehicleListEntry(id: "123", name: "My Tesla"))

    #expect(VehicleCommand.hvacOn(temperatureC: 21.0) == .hvacOn(temperatureC: 21.0))
    #expect(VehicleCommand.setChargeLimit(percent: 80).isDangerous == false)
    #expect(VehicleCommand.doorOpen(.trunk).isDangerous)
}
