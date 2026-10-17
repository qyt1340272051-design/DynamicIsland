import Foundation

/// Host assessment of a validated execution profile. A successful individual
/// layout never upgrades a profile whose protocol implementation is partial.
public nonisolated enum PluginCompatibilityLevel: String, CaseIterable, Equatable, Sendable {
    case native, compatible, limited

    public var title: String {
        switch self {
        case .native: "原生"
        case .compatible: "兼容"
        case .limited: "有限兼容"
        }
    }

    public var description: String {
        switch self {
        case .native: "使用主程序的原生 JavaScriptCore 插件接口。"
        case .compatible: "主程序支持此兼容协议的完整约定。"
        case .limited: "主程序仅实现兼容协议的有界子集，运行成功不代表完整兼容。"
        }
    }
}

/// Static differences belong to the Host's implementation, not to package
/// metadata, plugin logs, or success claims supplied by JavaScript.
public nonisolated enum PluginCompatibilityProfileLimitation: String, CaseIterable, Hashable, Sendable {
    case boundedViews
    case synchronousCallbacks
    case hostPresentationPolicy
    case noWindowState
    case noUpstreamResourceAPIs
    case hostDrivenRefresh

    public var title: String {
        switch self {
        case .boundedViews: "有限视图类型"
        case .synchronousCallbacks: "仅同步模块回调"
        case .hostPresentationPolicy: "展示请求由主程序裁决"
        case .noWindowState: "不提供上游窗口状态"
        case .noUpstreamResourceAPIs: "不提供上游资源接口"
        case .hostDrivenRefresh: "刷新由主程序驱动"
        }
    }

    public var description: String {
        switch self {
        case .boundedViews:
            "支持文字、图标、横排、竖排、进度和按钮；视图深度、数量和字段受主程序限制。"
        case .synchronousCallbacks:
            "模块生命周期与动作回调须同步返回，不支持异步或生成器回调。"
        case .hostPresentationPolicy:
            "展开与收起会转换为有期限的展示请求，仍由主程序检查能力声明和当前交互状态。"
        case .noWindowState:
            "不提供上游窗口状态读取或全局窗口控制。"
        case .noUpstreamResourceAPIs:
            "不映射上游文件、网络或其他系统资源接口；主程序资源访问仍须使用已支持的接口与授权。"
        case .hostDrivenRefresh:
            "布局随模块启动、动作和展示请求刷新，不支持上游的任意刷新调度接口。"
        }
    }
}

/// Only fixed converter observations can become retained layout details. The
/// enum deliberately has no arbitrary string or plugin-supplied message case.
public nonisolated enum PluginCompatibilityLayoutLimitation: String, CaseIterable, Hashable, Sendable {
    case hostTextTypography
    case hostTextLineLimit
    case hostIconAppearance
    case hostStackSpacing
    case hostStackAlignment
    case hostStackDistribution
    case semanticColors
    case hostButtonAppearance

    public var title: String {
        switch self {
        case .hostTextTypography: "文字样式由主程序调整"
        case .hostTextLineLimit: "文字行数由主程序限制"
        case .hostIconAppearance: "图标外观由主程序调整"
        case .hostStackSpacing: "布局间距由主程序调整"
        case .hostStackAlignment: "布局对齐由主程序调整"
        case .hostStackDistribution: "布局分布由主程序调整"
        case .semanticColors: "颜色转换为主程序语义色"
        case .hostButtonAppearance: "按钮外观由主程序调整"
        }
    }

    public var description: String {
        switch self {
        case .hostTextTypography: "请求的文字尺寸或字形样式转换为主程序支持的文字样式。"
        case .hostTextLineLimit: "请求的文字行数由主程序的节点规则约束。"
        case .hostIconAppearance: "请求的图标尺寸或外观转换为主程序支持的图标样式。"
        case .hostStackSpacing: "请求的横排或竖排间距转换为主程序支持的间距。"
        case .hostStackAlignment: "请求的横排或竖排对齐方式由主程序布局规则替代。"
        case .hostStackDistribution: "请求的横排或竖排分布方式由主程序布局规则替代。"
        case .semanticColors: "请求的颜色转换为主程序支持的语义色，不保证与上游外观完全相同。"
        case .hostButtonAppearance: "按钮使用主程序的控件外观和交互规则。"
        }
    }
}

public nonisolated enum PluginCompatibilityObservation: String, CaseIterable, Equatable, Sendable {
    case notRun, awaitingLayout, rendered

    public var title: String {
        switch self {
        case .notRun: "当前未运行"
        case .awaitingLayout: "运行中，尚无成功布局"
        case .rendered: "最近成功布局"
        }
    }

    public var description: String {
        switch self {
        case .notRun: "当前没有本次执行的兼容布局结果，启用偏好不代表插件正在运行。"
        case .awaitingLayout: "已开始本次执行，尚未接受成功的兼容布局。"
        case .rendered: "仅记录本次执行中最近一次成功发布的布局，未覆盖的功能仍受静态兼容限制。"
        }
    }
}

/// Process-only, data-only assessment. Lifecycle owns the execution token and
/// exact validated-package binding; this snapshot cannot authorize execution.
public nonisolated struct PluginCompatibilitySnapshot: Equatable, Sendable {
    public let engine: PluginEngine
    public let level: PluginCompatibilityLevel
    public let profileLimitations: Set<PluginCompatibilityProfileLimitation>
    public let observation: PluginCompatibilityObservation
    public let layoutLimitations: Set<PluginCompatibilityLayoutLimitation>

    public var profileLimitationsInDisplayOrder: [PluginCompatibilityProfileLimitation] {
        PluginCompatibilityProfileLimitation.allCases.filter { profileLimitations.contains($0) }
    }

    public var layoutLimitationsInDisplayOrder: [PluginCompatibilityLayoutLimitation] {
        PluginCompatibilityLayoutLimitation.allCases.filter { layoutLimitations.contains($0) }
    }

    /// Installation previews may display this static assessment without ever
    /// executing the staged package or borrowing a same-ID installed report.
    public static func profile(for engine: PluginEngine) -> Self {
        switch engine {
        case .javaScriptCore:
            .init(engine: engine, level: .native, profileLimitations: [],
                  observation: .notRun, layoutLimitations: [])
        case .superIsland:
            .init(engine: engine, level: .limited,
                  profileLimitations: Set(PluginCompatibilityProfileLimitation.allCases),
                  observation: .notRun, layoutLimitations: [])
        }
    }

    func executionDidStart() -> Self {
        .init(engine: engine, level: level, profileLimitations: profileLimitations,
              observation: .awaitingLayout, layoutLimitations: [])
    }

    func recordingLayout(_ limitations: Set<PluginCompatibilityLayoutLimitation>) -> Self {
        .init(engine: engine, level: level, profileLimitations: profileLimitations,
              observation: .rendered, layoutLimitations: limitations)
    }
}
