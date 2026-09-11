import AppKit
import SwiftUI
import CodexTopCore

/// Keep the native thumb and the stored percentage on the same thirteen ticks.
struct MonitorScaleSlider: NSViewRepresentable {
    @Binding var percentage: Double

    func makeCoordinator() -> Coordinator { Coordinator(percentage: $percentage) }

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(frame: .zero)
        slider.sliderType = .linear
        slider.isVertical = false
        slider.minValue = MonitorScale.minimum * 100
        slider.maxValue = MonitorScale.maximum * 100
        slider.numberOfTickMarks = Int(((MonitorScale.maximum - MonitorScale.minimum) / MonitorScale.step).rounded()) + 1
        slider.allowsTickMarkValuesOnly = true
        slider.isContinuous = true
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        slider.doubleValue = percentage
        slider.setAccessibilityLabel("显示比例")
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        slider.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.percentage = $percentage
        // Reset buttons and preference changes also move the native thumb.
        if slider.doubleValue != percentage { slider.doubleValue = percentage }
    }

    static func dismantleNSView(_ slider: NSSlider, coordinator: Coordinator) {
        slider.target = nil
        slider.action = nil
    }

    @MainActor final class Coordinator: NSObject {
        var percentage: Binding<Double>

        init(percentage: Binding<Double>) { self.percentage = percentage }

        @objc func changed(_ slider: NSSlider) {
            percentage.wrappedValue = slider.doubleValue.rounded()
        }
    }
}
