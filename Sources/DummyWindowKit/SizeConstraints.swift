public import TesseraCore

/// The size a test window accepts when asked for `requested`, applied in a fixed order
/// so tests can predict it: aspect ratio, then min/max clamp, then quantum snapping.
public enum SizeConstraints {
    public static func accepted(_ requested: Size, spec: WindowSpec) -> Size {
        var size = requested

        if let ratio = spec.aspectRatio, ratio.width > 0, ratio.height > 0 {
            size.height = roundedDivision(size.width * ratio.height, by: ratio.width)
        }

        size = clamp(size, min: spec.minSize, max: spec.maxSize)

        if let quantum = spec.quantum {
            let base = spec.minSize ?? .zero
            size.width = snap(size.width, base: base.width, step: quantum.width, max: spec.maxSize?.width)
            size.height = snap(size.height, base: base.height, step: quantum.height, max: spec.maxSize?.height)
        }
        return size
    }

    static func clamp(_ size: Size, min minSize: Size?, max maxSize: Size?) -> Size {
        var result = size
        if let maxSize {
            result.width = Swift.min(result.width, maxSize.width)
            result.height = Swift.min(result.height, maxSize.height)
        }
        if let minSize {
            result.width = Swift.max(result.width, minSize.width)
            result.height = Swift.max(result.height, minSize.height)
        }
        return result
    }

    /// Rounds down onto the grid `base + k·step`, never below `base`, never above `max`.
    static func snap(_ value: Int, base: Int, step: Int, max maxValue: Int?) -> Int {
        guard step > 1, value > base else { return Swift.max(value, base) }
        var snapped = base + ((value - base) / step) * step
        if let maxValue, snapped > maxValue { snapped -= step }
        return Swift.max(snapped, base)
    }

    static func roundedDivision(_ numerator: Int, by denominator: Int) -> Int {
        (2 * numerator + denominator) / (2 * denominator)
    }
}
