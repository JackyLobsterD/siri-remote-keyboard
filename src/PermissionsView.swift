import SwiftUI
import AppKit
import IOKit.hid
import ApplicationServices

/// Live status of the two permissions. Polled, because macOS gives no
/// notification when either one is toggled.
final class PermissionModel: ObservableObject {
    @Published var accessibility = false
    @Published var inputMonitoring = false
    /// Input Monitoring is usually only picked up after a relaunch, so offer one
    /// rather than leaving the user wondering why nothing happened.
    @Published var needsRelaunch = false

    private var hidWasDeniedAtLaunch = false

    init() {
        hidWasDeniedAtLaunch = !Self.hidOK()
        refresh()
    }

    static func axOK() -> Bool { AXIsProcessTrusted() }
    static func hidOK() -> Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    func refresh() {
        accessibility = Self.axOK()
        inputMonitoring = Self.hidOK()
        needsRelaunch = inputMonitoring && hidWasDeniedAtLaunch
    }

    /// Receivers only synthesise keys sent over the network; they never read
    /// the remote, so Input Monitoring is irrelevant there.
    var needsInputMonitoring: Bool { RelaySettings.role != .receiver }

    var allGranted: Bool {
        accessibility && (!needsInputMonitoring || (inputMonitoring && !needsRelaunch))
    }

    func request() {
        if !accessibility {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }
        if needsInputMonitoring, !inputMonitoring { _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) }
    }
}

struct PermissionsView: View {
    @ObservedObject var model: PermissionModel
    var onRelaunch: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.needsInputMonitoring ? "SiriRemoted 需要两个权限" : "SiriRemoted（接收端）需要一个权限").font(.title3.weight(.semibold))
                Text("两个是分开授权的，都打开后这个窗口会自动关闭。")
                    .font(.callout).foregroundStyle(.secondary)
            }

            row(title: "辅助功能",
                detail: "合成键盘事件 — 把遥控器按键变成真正的键盘输入",
                granted: model.accessibility,
                pane: "Privacy_Accessibility")

            if model.needsInputMonitoring {
                row(title: "输入监控",
                    detail: "读取遥控器的按键 — 没有它就收不到任何输入",
                    granted: model.inputMonitoring,
                    pane: "Privacy_ListenEvent")
            }

            if model.needsInputMonitoring && model.needsRelaunch {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("输入监控需要重启 App 才会生效").font(.callout.weight(.medium))
                        Text("这是 macOS 的限制，不是配置问题。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    SwiftUI.Button("重启", action: onRelaunch)
                        .controlSize(.regular)
                }
                .padding(11)
                .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            }

            Text("在列表里找不到 SiriRemoted？点面板左下角的 + ，选 /Applications/SiriRemoted.app")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .frame(width: 470)
    }

    private func row(title: String, detail: String, granted: Bool, pane: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 19))
                .foregroundStyle(granted ? Color.green : Color.secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)

            if granted {
                Text("已开启").font(.callout).foregroundStyle(.green)
            } else {
                SwiftUI.Button("打开设置") {
                    NSWorkspace.shared.open(URL(string:
                        "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .unemphasizedSelectedContentBackgroundColor).opacity(0.5),
                    in: RoundedRectangle(cornerRadius: 9))
    }
}
