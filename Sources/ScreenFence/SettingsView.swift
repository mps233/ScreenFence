import AppKit
import SwiftUI

private enum FenceStyle {
    static let background = Color(red: 0.957, green: 0.969, blue: 0.984)
    static let ink = Color(red: 0.106, green: 0.149, blue: 0.224)
    static let secondary = Color(red: 0.408, green: 0.459, blue: 0.545)
    static let accent = Color(red: 0.141, green: 0.365, blue: 0.847)
    static let line = Color(red: 0.863, green: 0.890, blue: 0.933)
    static let softBlue = Color(red: 0.929, green: 0.953, blue: 1)
}

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if !model.permissionGranted {
                    permissionNotice
                }
                displaySection
                lockSection
                shortcutSection
                footer
            }
            .padding(24)
        }
        .background(FenceStyle.background)
        .foregroundStyle(FenceStyle.ink)
        .tint(FenceStyle.accent)
        .frame(minWidth: 610, idealWidth: 640, minHeight: 580, idealHeight: 640)
        .preferredColorScheme(.light)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "cursorarrow.and.square.on.square.dashed")
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(FenceStyle.accent)
                .frame(width: 46, height: 46)
                .background(.white, in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12).stroke(FenceStyle.line)
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("屏界")
                    .font(.system(size: 25, weight: .semibold, design: .rounded))
                Text("把鼠标留在这一屏")
                    .font(.system(size: 13))
                    .foregroundStyle(FenceStyle.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(model.isLocked ? FenceStyle.accent : FenceStyle.secondary)
                    .frame(width: 6, height: 6)
                Text(model.isLocked ? "已锁定" : "未锁定")
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(.white, in: Capsule())
            .accessibilityLabel(model.isLocked ? "鼠标已锁定" : "鼠标未锁定")
        }
    }

    private var permissionNotice: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "hand.raised")
                .font(.system(size: 18))
                .foregroundStyle(FenceStyle.accent)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                Text("先允许屏界使用辅助功能")
                    .font(.system(size: 13, weight: .semibold))
                Text("在「隐私与安全性 → 辅助功能」中开启「屏界」，然后返回这里。")
                    .font(.system(size: 12))
                    .foregroundStyle(FenceStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button("打开系统设置", action: model.openAccessibilitySettings)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("重新检查", action: model.refreshPermissions)
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(FenceStyle.softBlue, in: RoundedRectangle(cornerRadius: 10))
    }

    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("锁定哪块屏幕")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(model.displays.count) 块显示器")
                    .font(.system(size: 11))
                    .foregroundStyle(FenceStyle.secondary)
            }
            DisplayTopology(
                displays: model.displays,
                selectedID: $model.selectedDisplayID,
                lockedID: model.lockedDisplayID,
                selectionEnabled: !model.isLocked && model.countdown == 0
            )
            .frame(height: 196)
            .background(FenceStyle.background, in: RoundedRectangle(cornerRadius: 8))
            Picker("目标屏幕", selection: $model.selectedDisplayID) {
                Text("快捷键按下时，鼠标所在的屏幕").tag(UInt32(0))
                ForEach(model.displays) { display in
                    Text(display.name + (display.isMain ? " · 主屏幕" : ""))
                        .tag(display.id)
                }
            }
            .pickerStyle(.menu)
            .font(.system(size: 12))
            .disabled(model.isLocked || model.countdown > 0)
            .accessibilityHint("也可以点上方的显示器来选择。")
        }
        .padding(16)
        .background(.white, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).stroke(FenceStyle.line)
        }
    }

    private var lockSection: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.isLocked ? "全局锁定已开启" : "选择一块屏幕，全局锁定")
                        .font(.system(size: 14, weight: .semibold))
                    Text(lockExplanation)
                        .font(.system(size: 12))
                        .foregroundStyle(FenceStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button(action: primaryAction) {
                    Label(
                        primaryTitle,
                        systemImage: model.countdown > 0 ? "xmark" : (model.isLocked ? "lock.open" : "lock")
                    )
                        .font(.system(size: 13, weight: .semibold))
                        .frame(minWidth: 104)
                        .padding(.vertical, 3)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityHint(
                    model.countdown > 0 ? "立即取消本次锁定。" :
                        (model.isLocked ? "立即恢复跨屏移动。" : "等待三秒后锁定，在倒计时期间将鼠标移到目标屏幕。")
                )
            }
            Divider()
            Label("所有 App 共用这一块屏幕范围", systemImage: "globe")
                .font(.system(size: 12))
                .foregroundStyle(FenceStyle.secondary)
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: model.isLocked ? "lock.shield" : "info.circle")
                    .padding(.top, 1)
                Text(model.statusMessage)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .font(.system(size: 11))
            .foregroundStyle(FenceStyle.secondary)
            .accessibilityElement(children: .combine)
        }
        .padding(16)
        .background(.white, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).stroke(FenceStyle.line)
        }
    }

    private var shortcutSection: some View {
        HStack(alignment: .top, spacing: 24) {
            shortcut("锁定 / 解除", keys: "⌘ L")
            Divider().frame(height: 32)
            shortcut("紧急解除", keys: "⌃ ⌥ ⌘ Esc")
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 5) {
                Label("右边仍可上下移动", systemImage: "arrow.up.and.down")
                Label("下边仍可左右移动", systemImage: "arrow.left.and.right")
            }
            .font(.system(size: 11))
            .foregroundStyle(FenceStyle.secondary)
        }
        .padding(.horizontal, 2)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Text("保持到手动解除；显示器变化或休眠时自动解除。")
                .font(.system(size: 10))
                .foregroundStyle(FenceStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("使用说明", action: model.openReadme)
            Button("复制诊断", action: model.copyDiagnostics)
                .help(model.diagnosticSummary)
        }
        .buttonStyle(.link)
        .font(.system(size: 11))
    }

    private var lockExplanation: String {
        if model.countdown > 0 {
            return "\(model.countdown) 秒后生效，现在把鼠标移到要锁定的屏幕。"
        }
        if model.isLocked {
            return "全局生效，切换 App 仍保持锁定。需要跨屏时，按快捷键或点击解除。"
        }
        return "全局生效，切换 App 仍保持锁定。点击后有 3 秒时间把鼠标移到目标屏幕。"
    }

    private var primaryTitle: String {
        if model.countdown > 0 { return "取消倒计时" }
        if model.isLocked { return "解除锁定" }
        if !model.permissionGranted { return "开启权限" }
        return "3 秒后锁定"
    }

    private func primaryAction() {
        if model.countdown > 0 || model.isLocked {
            model.unlock()
        } else if !model.permissionGranted {
            model.requestPermission()
        } else {
            model.beginLockCountdown()
        }
    }

    private func shortcut(_ title: String, keys: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(FenceStyle.secondary)
            Text(keys)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
        }
        .accessibilityElement(children: .combine)
    }
}

private struct DisplayTopology: View {
    let displays: [DisplayInfo]
    @Binding var selectedID: UInt32
    let lockedID: UInt32?
    let selectionEnabled: Bool

    var body: some View {
        GeometryReader { proxy in
            if displays.isEmpty {
                Text("正在读取显示器…")
                    .font(.system(size: 12))
                    .foregroundStyle(FenceStyle.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let union = displays.reduce(CGRect.null) { $0.union($1.bounds) }
                let available = CGSize(
                    width: max(1, proxy.size.width - 40),
                    height: max(1, proxy.size.height - 28)
                )
                let scale = min(
                    available.width / max(1, union.width),
                    available.height / max(1, union.height)
                )
                let origin = CGPoint(
                    x: (proxy.size.width - union.width * scale) / 2,
                    y: (proxy.size.height - union.height * scale) / 2
                )
                ForEach(displays) { display in
                    let size = CGSize(
                        width: max(1, display.bounds.width * scale - 6),
                        height: max(1, display.bounds.height * scale - 6)
                    )
                    displayButton(display, size: size)
                        .frame(width: size.width, height: size.height)
                        .position(
                            x: origin.x + (display.bounds.midX - union.minX) * scale,
                            y: origin.y + (display.bounds.midY - union.minY) * scale
                        )
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("当前显示器排列，点按显示器可选择锁定目标")
    }

    private func displayButton(_ display: DisplayInfo, size: CGSize) -> some View {
        let active = lockedID == display.id || (lockedID == nil && selectedID == display.id)
        let showName = size.width >= 64 && size.height >= 42
        let showResolution = size.width >= 86 && size.height >= 58
        let name = CGDisplayIsBuiltin(display.id) != 0 ? "内建显示器" : display.name
        return Button {
            selectedID = display.id
        } label: {
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(active ? FenceStyle.softBlue : Color.white)
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(active ? FenceStyle.accent : FenceStyle.line, lineWidth: active ? 2 : 1)
                if display.isMain {
                    Capsule()
                        .fill(active ? FenceStyle.accent : FenceStyle.secondary.opacity(0.45))
                        .frame(width: min(35, size.width * 0.3), height: 3)
                        .padding(.top, 5)
                }
                VStack(spacing: 3) {
                    Image(systemName: lockedID == display.id ? "lock.fill" : "display")
                        .resizable()
                        .scaledToFit()
                        .frame(
                            width: min(18, max(1, size.width - 12)),
                            height: min(14, max(1, size.height - 12))
                        )
                        .foregroundStyle(active ? FenceStyle.accent : FenceStyle.secondary)
                    if showName {
                        Text(name)
                            .font(.system(size: 11, weight: active ? .semibold : .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    if showResolution {
                        Text(display.resolution)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(FenceStyle.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, showName ? 8 : 2)
                .padding(.top, display.isMain ? 8 : 0)
                .padding(.bottom, 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(!selectionEnabled)
        .opacity(1)
        .accessibilityLabel(display.name + "，" + display.resolution + (display.isMain ? "，主屏幕" : "") + (active ? "，当前目标" : ""))
        .help(display.name + " · " + display.resolution)
    }
}
