import SwiftUI

struct ContentView: View {
    @ObservedObject var controller: CleaningController

    private var needsAccessibility: Bool {
        controller.disableKeyboard || controller.disableTrackpad
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {

            VStack(spacing: 0) {
                ToggleRow(
                    icon: "keyboard",
                    title: "禁用键盘",
                    subtitle: "拦截所有按键，擦键盘不误触",
                    isOn: $controller.disableKeyboard
                )
                Divider()
                ToggleRow(
                    icon: "rectangle.and.hand.point.up.left",
                    title: "禁用触控板 / 鼠标",
                    subtitle: "拦截点击、移动与滚动",
                    isOn: $controller.disableTrackpad
                )
                Divider()
                ToggleRow(
                    icon: "moon.fill",
                    title: "黑屏",
                    subtitle: "全屏纯黑，方便看清污渍",
                    isOn: $controller.blackScreen
                )
            }
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            if needsAccessibility {
                permissionSection
            }

            startButton

            Text("退出清洁模式：**按住 Esc 键 2 秒**")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)

            Divider()

            Button(role: .destructive) {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("退出应用", systemImage: "power")
                    .font(.footnote)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { controller.refreshPermission() }
    }


    @ViewBuilder
    private var permissionSection: some View {
        if controller.accessibilityGranted {
            Label("已获得辅助功能权限", systemImage: "checkmark.seal.fill")
                .font(.footnote)
                .foregroundStyle(.green)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label("需要「辅助功能」权限才能拦截输入", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.orange)
                Text("点击「开始」会弹出授权请求；授权后请回到本应用重新开始。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("打开系统设置 › 辅助功能") {
                    controller.openAccessibilitySettings()
                }
                .font(.caption)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private var startButton: some View {
        Button(action: controller.start) {
            Text("开始清洁")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!controller.canStart)
    }
}

private struct ToggleRow: View {
    let icon: String
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .frame(width: 26)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { isOn.toggle() }
    }
}

#Preview {
    ContentView(controller: CleaningController())
}
