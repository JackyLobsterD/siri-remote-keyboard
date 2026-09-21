import SwiftUI

extension Button {
    var displayName: String {
        switch self {
        case .ringUp:    return "环 · 上"
        case .ringDown:  return "环 · 下"
        case .ringLeft:  return "环 · 左"
        case .ringRight: return "环 · 右"
        case .center:    return "环 · 中心"
        case .back:      return "返回 ‹"
        case .tv:        return "TV"
        case .playPause: return "播放 / 暂停"
        case .mute:      return "静音"
        case .volUp:     return "音量 +"
        case .volDown:   return "音量 −"
        case .siri:      return "侧边 Siri 键"
        }
    }

    var usageLabel: String {
        guard let key = usageToButton.first(where: { $0.value == self })?.key else { return "" }
        return String(format: "0x%02X/0x%02X", UInt32(key >> 32), UInt32(key & 0xFFFF_FFFF))
    }

    static let ordered: [Button] = [
        .ringUp, .ringDown, .ringLeft, .ringRight, .center,
        .back, .tv, .playPause, .mute, .volUp, .volDown, .siri,
    ]
}

struct SettingsView: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var relay: RelayStatus
    @State private var layerIndex = 0
    @State private var selected: Button? = .ringUp

    var body: some View {
        TabView {
            keysTab.tabItem { Label("按键", systemImage: "dot.circle.and.hand.point.up.left.fill") }
            timingTab.tabItem { Label("时间与通用", systemImage: "slider.horizontal.3") }
            RelaySettingsView(status: relay)
                .tabItem { Label("多电脑", systemImage: "desktopcomputer.and.arrow.down") }
        }
        .frame(minWidth: 720, minHeight: 460)
        .onAppear { if layerIndex >= store.config.layers.count { layerIndex = 0 } }
    }

    // MARK: Keys

    private var keysTab: some View {
        VStack(spacing: 0) {
            layerBar
            Divider()
            HSplitView {
                buttonList
                detailPane
            }
        }
    }

    private var layerBar: some View {
        HStack(spacing: 10) {
            Text("Layer").foregroundStyle(.secondary).font(.callout)
            Picker("", selection: $layerIndex) {
                ForEach(Array(store.config.layers.enumerated()), id: \.offset) { i, l in
                    Text(l.name).tag(i)
                }
            }
            .labelsHidden()
            .frame(width: 170)

            SwiftUI.Button { store.addLayer(); layerIndex = store.config.layers.count - 1 } label: {
                Image(systemName: "plus")
            }
            .help("新增一层")

            SwiftUI.Button {
                let i = layerIndex
                layerIndex = max(0, i - 1)
                store.removeLayer(i)
            } label: { Image(systemName: "minus") }
            .disabled(store.config.layers.count <= 1)
            .help("删除当前层")

            if layerIndex > 0, layerIndex < store.config.layers.count {
                Toggle("未定义的键沿用 base", isOn: Binding(
                    get: { store.config.layers[layerIndex].fallthroughToBase ?? true },
                    set: { store.config.layers[layerIndex].fallthroughToBase = $0; store.save() }
                ))
                .font(.callout)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var buttonList: some View {
        List(Button.ordered, id: \.self, selection: $selected) { b in
            let bind = store.binding(layer: layerIndex, button: b)
            VStack(alignment: .leading, spacing: 2) {
                Text(b.displayName).font(.system(size: 13, weight: .medium))
                Text(bind.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(bind.isEmpty ? .tertiary : .secondary)
                    .lineLimit(1)
            }
            .padding(.vertical, 2)
            .tag(b)
        }
        .frame(minWidth: 210, idealWidth: 230, maxWidth: 300)
    }

    @ViewBuilder
    private var detailPane: some View {
        if let b = selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(b.displayName).font(.title3.weight(.semibold))
                        Text(b.usageLabel)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }

                    let bind = store.binding(layer: layerIndex, button: b)

                    if bind.whileHeld != nil {
                        Label("「按住不放」已设置，下面的单击 / 双击 / 长按都不会生效。",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }

                    gestureRow("单击", b, \.tap, showRepeat: true)
                    gestureRow("双击", b, \.double)
                    gestureRow("三击", b, \.triple)
                    gestureRow("长按", b, \.hold)
                    gestureRow("更长按", b, \.hold2)

                    Divider()

                    gestureRow("按住不放", b, \.whileHeld)

                    Divider()

                    bindingSoundRow(b)
                    Text("按住多久，这个键就被按住多久。侧边 Siri 键的语音输入就是靠它 —— "
                         + "按住时一直按着右 Option，Wispr 便一直在录。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 0)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text("选一个按键").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func gestureRow(_ title: String, _ b: Button,
                            _ path: WritableKeyPath<ButtonBinding, String?>,
                            showRepeat: Bool = false) -> some View {
        let current = store.binding(layer: layerIndex, button: b)
        return HStack(spacing: 10) {
            Text(title)
                .font(.callout)
                .frame(width: 66, alignment: .leading)
                .foregroundStyle(.secondary)

            ActionEditor(
                action: Action.parse(current[keyPath: path]),
                layers: store.config.layers.map(\.name)
            ) { newAction in
                var v = store.binding(layer: layerIndex, button: b)
                v[keyPath: path] = newAction.encoded
                store.setBinding(v, layer: layerIndex, button: b)
            }

            if showRepeat {
                Toggle("按住连发", isOn: Binding(
                    get: { store.binding(layer: layerIndex, button: b).autoRepeat ?? false },
                    set: {
                        var v = store.binding(layer: layerIndex, button: b)
                        v.autoRepeat = $0 ? true : nil
                        store.setBinding(v, layer: layerIndex, button: b)
                    }
                ))
                .font(.system(size: 11))
                .toggleStyle(.checkbox)
            }
            Spacer()
        }
    }

    // MARK: Timing

    private var timingTab: some View {
        Form {
            Section {
                msRow("双击判定窗口", \.doubleTapWindowMs, 280, 120...600,
                      "越短单击越跟手，但双击越难按出来。只有设了双击/三击的键才会等这段时间。")
                msRow("长按阈值", \.holdThresholdMs, 350, 150...1200, nil)
                msRow("更长按阈值", \.hold2ThresholdMs, 900, 400...2500, nil)
            } header: { Text("手势判定") }

            Section {
                msRow("连发起始延迟", \.repeatDelayMs, 350, 100...1000, nil)
                msRow("连发间隔", \.repeatIntervalMs, 60, 20...300, nil)
            } header: { Text("按住连发") }

            Section {
                msRow("leader 等待时间", \.oneShotTimeoutMs, 1500, 500...3000,
                      "按了 TV 之后，等多久没按别的键就自动作废。")
            } header: { Text("Leader 键") }

            Section {
                Toggle("播放提示音", isOn: Binding(
                    get: { store.config.settings?.layerChangeSound ?? true },
                    set: {
                        if store.config.settings == nil { store.config.settings = Settings() }
                        store.config.settings?.layerChangeSound = $0
                        store.save()
                    }
                ))
                soundRow("leader 上膛", \.leaderArmedSound, "Tink")
                soundRow("leader 过期", \.leaderExpiredSound, "Purr")
                soundRow("切换 layer", \.layerSwitchSound, "Morse")
                Text("选中即试听。上膛和过期最好选两个听起来明显不同的，一耳朵就能分辨。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } header: { Text("声音") }

            Section {
                Text("配置文件：\(Config.path)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("手改这个文件也会即时生效；但在这里保存会把文件重写成纯 JSON，注释会丢。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } header: { Text("配置") }
        }
        .formStyle(.grouped)
    }

    /// Sound played when this button's action fires.
    private func bindingSoundRow(_ b: Button) -> some View {
        let current = store.binding(layer: layerIndex, button: b).sound ?? "none"
        return HStack(spacing: 10) {
            Text("音效").font(.callout).frame(width: 66, alignment: .leading)
                .foregroundStyle(.secondary)
            Picker("", selection: Binding(
                get: { current },
                set: { v in
                    var bind = store.binding(layer: layerIndex, button: b)
                    bind.sound = v == "none" ? nil : v
                    store.setBinding(bind, layer: layerIndex, button: b)
                    Sounds.play(v)
                }
            )) {
                Text("无").tag("none")
                ForEach(Sounds.groups, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.options, id: \.id) { o in
                            Text("\(o.name)   \(String(format: "%.2fs", o.duration))").tag(o.id)
                        }
                    }
                }
            }
            .labelsHidden()
            .frame(width: 250)
            SwiftUI.Button { Sounds.play(current) } label: { Image(systemName: "play.circle.fill") }
                .buttonStyle(.borderless)
                .disabled(current == "none")
            Spacer()
        }
    }

    private func soundRow(_ title: String, _ path: WritableKeyPath<Settings, String?>,
                          _ fallback: String) -> some View {
        let current = store.config.settings?[keyPath: path] ?? fallback
        let enabled = store.config.settings?.layerChangeSound ?? true
        return HStack {
            Text(title)
            Spacer()
            Picker("", selection: Binding(
                get: { current },
                set: { v in
                    if store.config.settings == nil { store.config.settings = Settings() }
                    store.config.settings?[keyPath: path] = v
                    store.save()
                    Sounds.play(v)          // hear it the moment it's picked
                }
            )) {
                Text("无").tag("none")
                ForEach(Sounds.groups, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.options, id: \.id) { o in
                            Text("\(o.name)   \(String(format: "%.2fs", o.duration))").tag(o.id)
                        }
                    }
                }
            }
            .labelsHidden()
            .frame(width: 250)

            SwiftUI.Button { Sounds.play(current) } label: {
                Image(systemName: "play.circle.fill")
            }
            .buttonStyle(.borderless)
            .disabled(current == "none")
            .help("试听")
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }

    private func msRow(_ title: String, _ path: WritableKeyPath<Settings, Int?>,
                       _ fallback: Int, _ range: ClosedRange<Double>, _ note: String?) -> some View {
        let value = Binding<Double>(
            get: { Double(store.config.settings?[keyPath: path] ?? fallback) },
            set: {
                if store.config.settings == nil { store.config.settings = Settings() }
                store.config.settings?[keyPath: path] = Int($0)
                store.save()
            }
        )
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value.wrappedValue)) ms")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
            if let note {
                Text(note).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Kind picker plus whatever that kind needs (a key recorder, or a layer menu).
struct ActionEditor: View {
    let action: Action
    let layers: [String]
    let onChange: (Action) -> Void

    @State private var keyText: String = ""

    var body: some View {
        HStack(spacing: 8) {
            Picker("", selection: Binding(
                get: { action.kindIndex },
                set: { emit(kind: $0) }
            )) {
                Text("无").tag(0)
                Text("按键").tag(1)
                Text("下一层").tag(2)
                Text("上一层").tag(3)
                Text("切到指定层").tag(4)
                Text("按住 = 某层").tag(5)
                Text("leader（点一下，下个键生效）").tag(6)
                Text("切换电脑").tag(7)
            }
            .labelsHidden()
            .frame(width: 125)

            switch action {
            case .key(let k):
                KeyRecorder(value: Binding(get: { k }, set: { _ in })) { captured in
                    onChange(.key(captured))
                }
                .frame(width: 150, height: 24)
                SwiftUI.Button { onChange(.none) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tertiary)
                    .help("清除")

            case .target(let t):
                Picker("", selection: Binding(get: { t }, set: { onChange(.target($0)) })) {
                    Text("下一台").tag("next")
                    Text("上一台").tag("prev")
                    Text("回到本机").tag("local")
                }
                .labelsHidden()
                .frame(width: 150)

            case .layerSet(let l), .layerMomentary(let l), .layerOneShot(let l):
                Picker("", selection: Binding(
                    get: { l },
                    set: { n in
                        switch action {
                        case .layerMomentary: onChange(.layerMomentary(n))
                        case .layerOneShot:   onChange(.layerOneShot(n))
                        default:              onChange(.layerSet(n))
                        }
                    }
                )) {
                    ForEach(layers, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 150)

            default:
                EmptyView()
            }
        }
    }

    private func emit(kind: Int) {
        switch kind {
        case 0: onChange(.none)
        case 1: onChange(.key(""))
        case 2: onChange(.layerNext)
        case 3: onChange(.layerPrev)
        case 4: onChange(.layerSet(layers.first ?? "base"))
        case 5: onChange(.layerMomentary(layers.count > 1 ? layers[1] : (layers.first ?? "base")))
        case 6: onChange(.layerOneShot(layers.count > 1 ? layers[1] : (layers.first ?? "base")))
        default: onChange(.target("next"))
        }
    }
}

/// Role, name and passcode for multi-Mac relaying. Changes apply on relaunch.
struct RelaySettingsView: View {
    @ObservedObject var status: RelayStatus
    @State private var role = RelaySettings.role
    @State private var name = RelaySettings.name
    @State private var passcode = RelaySettings.passcode

    private var dirty: Bool {
        role != RelaySettings.role || name != RelaySettings.name || passcode != RelaySettings.passcode
    }

    var body: some View {
        Form {
            Section {
                Picker("本机角色", selection: $role) {
                    ForEach(RelayRole.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Text(roleHelp).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: { Text("角色") }

            if role != .off {
                Section {
                    TextField("本机名字", text: $name)
                    Text("切换到这台电脑时，宿主机会念出这个名字。取短一点，比如「书房」「公司」。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    HStack {
                        TextField("配对码", text: $passcode)
                            .font(.system(.body, design: .monospaced))
                        SwiftUI.Button("随机生成") {
                            passcode = String((0..<8).map { _ in "23456789ABCDEFGHJKMNPQRSTUVWXYZ".randomElement()! })
                        }
                    }
                    Text("所有电脑填同一个。它就是加密密钥 —— 配对码不一样的电脑连不上，同一个 Wi-Fi 下的陌生设备也连不上。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } header: { Text("身份") }
            }

            Section {
                HStack {
                    Spacer()
                    SwiftUI.Button("保存并重启 SiriRemoted") {
                        RelaySettings.role = role
                        RelaySettings.name = name.trimmingCharacters(in: .whitespaces)
                        RelaySettings.passcode = passcode.trimmingCharacters(in: .whitespaces)
                        NotificationCenter.default.post(name: .siriRemotedRelaunch, object: nil)
                    }
                    .disabled(!dirty || (role != .off && passcode.trimmingCharacters(in: .whitespaces).isEmpty))
                    .keyboardShortcut(.defaultAction)
                }
            }

            if RelaySettings.role == .host {
                Section {
                    row("本机（\(RelaySettings.name)）", status.current == nil ? "● 正在控制" : "", true)
                    ForEach(status.peers) { p in
                        row(p.name, status.current == p.name ? "● 正在控制" : p.state, p.ready)
                    }
                    if !status.note.isEmpty {
                        Text(status.note).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                } header: { Text("局域网里的电脑") }
            } else if RelaySettings.role == .receiver {
                Section {
                    Text(status.note.isEmpty ? "—" : status.note)
                } header: { Text("状态") }
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ title: String, _ state: String, _ ok: Bool) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(ok ? Color.green : Color.orange)
            Text(title)
            Spacer()
            Text(state).font(.callout).foregroundStyle(.secondary)
        }
    }

    private var roleHelp: String {
        switch role {
        case .off:      return "只控制这一台电脑。"
        case .host:     return "遥控器连着这台。在遥控器上切换目标后，按键会通过局域网发给其他电脑。"
        case .receiver: return "这台不连遥控器，只接收宿主机发来的按键。只需要「辅助功能」权限。"
        }
    }
}
