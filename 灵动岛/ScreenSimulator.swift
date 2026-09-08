#if DEBUG
import AppKit
import Combine
import SwiftUI

@MainActor
final class ScreenSimulatorModel: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var configuration: ScreenSimulationConfiguration

    private let screenManager: ScreenManager

    init(screenManager: ScreenManager) {
        self.screenManager = screenManager
        self.isEnabled = screenManager.simulationConfiguration != nil
        self.configuration = screenManager.simulationConfiguration
            ?? SimulatedScreenProfile.macBookPro14.defaultConfiguration
    }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else {
            return
        }

        isEnabled = enabled
        apply()
    }

    func selectProfile(_ profile: SimulatedScreenProfile) {
        guard configuration.profile != profile else {
            return
        }

        configuration = profile.defaultConfiguration
        apply()
    }

    func setSimulatesNotch(_ simulatesNotch: Bool) {
        updateConfiguration { $0.simulatesNotch = simulatesNotch }
    }

    func setNotchWidth(_ width: CGFloat) {
        updateConfiguration { $0.notchWidth = width }
    }

    func setNotchHeight(_ height: CGFloat) {
        updateConfiguration { $0.notchHeight = height }
    }

    func setScaleFactor(_ scaleFactor: CGFloat) {
        updateConfiguration { $0.scaleFactor = scaleFactor }
    }

    func restoreProfileDefaults() {
        configuration = configuration.profile.defaultConfiguration
        apply()
    }

    private func updateConfiguration(_ update: (inout ScreenSimulationConfiguration) -> Void) {
        var updatedConfiguration = configuration
        update(&updatedConfiguration)
        updatedConfiguration = updatedConfiguration.normalized
        guard configuration != updatedConfiguration else {
            return
        }

        configuration = updatedConfiguration
        apply()
    }

    private func apply() {
        screenManager.setSimulationConfiguration(isEnabled ? configuration : nil)
    }
}

@MainActor
final class ScreenSimulatorWindowController: NSWindowController {
    private let model: ScreenSimulatorModel

    init(screenManager: ScreenManager) {
        let model = ScreenSimulatorModel(screenManager: screenManager)
        self.model = model

        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 440, height: 360),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "屏幕模拟器"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = CGSize(width: 420, height: 340)
        panel.contentViewController = NSHostingController(
            rootView: ScreenSimulatorView(model: model, screenManager: screenManager)
        )

        super.init(window: panel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        guard let window else {
            return
        }

        if !window.isVisible {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
    }
}

private struct ScreenSimulatorView: View {
    @ObservedObject var model: ScreenSimulatorModel
    @ObservedObject var screenManager: ScreenManager

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Toggle("启用屏幕模拟", isOn: enabledBinding)
                    .toggleStyle(.switch)

                Spacer(minLength: 8)

                Text(screenManager.physicalScreen?.name ?? "无可用屏幕")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Divider()

            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 12) {
                    Text("屏幕配置")
                        .frame(width: 72, alignment: .leading)
                    Picker("", selection: profileBinding) {
                        ForEach(SimulatedScreenProfile.allCases) { profile in
                            Text(profile.displayName).tag(profile)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity)
                }

                metricRow(title: "逻辑尺寸", value: formattedSize(model.configuration.logicalSize, suffix: "pt"))
                metricRow(title: "像素尺寸", value: formattedSize(model.configuration.pixelSize, suffix: "px"))

                Toggle("模拟刘海", isOn: notchEnabledBinding)

                sliderRow(
                    title: "刘海宽度",
                    value: notchWidthBinding,
                    range: Double(ScreenSimulationConfiguration.minimumNotchWidth)...Double(ScreenSimulationConfiguration.maximumNotchWidth),
                    step: 2,
                    valueText: "\(Int(model.configuration.notchWidth.rounded())) pt"
                )
                .disabled(!model.configuration.simulatesNotch)

                sliderRow(
                    title: "刘海高度",
                    value: notchHeightBinding,
                    range: Double(ScreenSimulationConfiguration.minimumNotchHeight)...Double(ScreenSimulationConfiguration.maximumNotchHeight),
                    step: 1,
                    valueText: "\(Int(model.configuration.notchHeight.rounded())) pt"
                )
                .disabled(!model.configuration.simulatesNotch)

                sliderRow(
                    title: "缩放倍率",
                    value: scaleFactorBinding,
                    range: Double(ScreenSimulationConfiguration.minimumScaleFactor)...Double(ScreenSimulationConfiguration.maximumScaleFactor),
                    step: 0.25,
                    valueText: String(format: "%.2fx", model.configuration.scaleFactor)
                )
            }
            .font(.system(size: 12))
            .disabled(!model.isEnabled)

            Divider()

            HStack(spacing: 8) {
                Label(
                    model.isEnabled ? "正在模拟" : "自动检测",
                    systemImage: model.isEnabled ? "display.2" : "display"
                )
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(model.isEnabled ? Color.accentColor : .secondary)

                Spacer(minLength: 8)

                Button {
                    model.restoreProfileDefaults()
                } label: {
                    Label("恢复默认值", systemImage: "arrow.counterclockwise")
                }
                .disabled(!model.isEnabled)
            }
        }
        .padding(18)
        .frame(minWidth: 420, idealWidth: 440, minHeight: 340, idealHeight: 360)
    }

    private var enabledBinding: Binding<Bool> {
        Binding(get: { model.isEnabled }, set: model.setEnabled)
    }

    private var profileBinding: Binding<SimulatedScreenProfile> {
        Binding(get: { model.configuration.profile }, set: model.selectProfile)
    }

    private var notchEnabledBinding: Binding<Bool> {
        Binding(get: { model.configuration.simulatesNotch }, set: model.setSimulatesNotch)
    }

    private var notchWidthBinding: Binding<Double> {
        Binding(
            get: { Double(model.configuration.notchWidth) },
            set: { model.setNotchWidth(CGFloat($0)) }
        )
    }

    private var notchHeightBinding: Binding<Double> {
        Binding(
            get: { Double(model.configuration.notchHeight) },
            set: { model.setNotchHeight(CGFloat($0)) }
        )
    }

    private var scaleFactorBinding: Binding<Double> {
        Binding(
            get: { Double(model.configuration.scaleFactor) },
            set: { model.setScaleFactor(CGFloat($0)) }
        )
    }

    private func metricRow(title: String, value: String) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private func sliderRow(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        valueText: String
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .frame(width: 72, alignment: .leading)
            Slider(value: value, in: range, step: step)
            Text(valueText)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .trailing)
        }
    }

    private func formattedSize(_ size: CGSize, suffix: String) -> String {
        "\(Int(size.width.rounded())) x \(Int(size.height.rounded())) \(suffix)"
    }
}
#endif
