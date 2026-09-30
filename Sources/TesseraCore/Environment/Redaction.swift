extension EnvironmentFixture {
    /// The same capture without anything that identifies this machine or its monitors: display
    /// UUIDs and serials, vendor/model numbers, the hardware model and the Spaces' display ids
    /// (audit F10). Everything the solver and the tests need stays.
    public func redacted() -> EnvironmentFixture {
        var copy = self
        copy.system.hardwareModel = "redacted"
        copy.displays = displays.map { display in
            var display = display
            display.uuid = nil
            display.serial = 0
            display.vendor = 0
            display.model = 0
            return display
        }
        copy.spaces.perDisplay = spaces.perDisplay.enumerated().map { index, entry in
            var entry = entry
            entry.displayIdentifier = entry.displayIdentifier == "Main" ? "Main" : "display-\(index + 1)"
            return entry
        }
        return copy
    }
}
