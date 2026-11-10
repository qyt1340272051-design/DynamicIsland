import SwiftUI

@MainActor
struct HomeNavigationSettingsView: View {
    @ObservedObject var settings: IslandHomeSettings

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("主页", systemImage: "house").font(.headline)
                Picker("展开时主页默认页面", selection: $settings.defaultLayer) {
                    ForEach(IslandHomeLayer.allCases) { layer in
                        Text(layer.title).tag(layer)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("settings-home-default-layer")
                .islandPagingExcluded()
                Text("每次展开时，主页从选定页面开始。展开后仍可自由切换。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                Toggle("显示主页选层按钮", isOn: $settings.showsLayerButtons)
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("settings-home-layer-buttons")
                    .islandPagingExcluded()
                Text("在主页居中显示音乐、日历、课程和会议按钮。关闭后仍可用双指横向滑动切换层。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
