import SwiftUI
import MoReadCore

extension ReaderKey {
    init(_ key: UIKey) {
        let flags = key.modifierFlags
        self.init(code: Int(key.keyCode.rawValue), modifiers: (flags.contains(.shift) ? 1 : 0) | (flags.contains(.control) ? 2 : 0) | (flags.contains(.alternate) ? 4 : 0) | (flags.contains(.command) ? 8 : 0))
    }
}

@MainActor
class ReaderKeyboardController: UIViewController {
    weak var keyboardSession: AutoReadSession?
    var keyboardReady: Bool { false }
    func turnWithKey(_ forward: Bool) {}
    private var keyboardActive = false
    private var held = Set<Int>()
    override var canBecomeFirstResponder: Bool { true }
    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(self, selector: #selector(updateKeyboard), name: UserDefaults.didChangeNotification, object: nil)
    }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); keyboardActive = false; updateKeyboard() }
    @objc func updateKeyboard() {
        let active = keyboardReady && ReaderKeys(data: UserDefaults.standard.data(forKey: "reader.keys") ?? Data()).enabled
        guard keyboardActive != active else { return }
        keyboardActive = active
        if active {
            DispatchQueue.main.async { [weak self] in
                guard let self, keyboardActive, keyboardReady, view.window != nil else { return }
                if let transition = transitionCoordinator {
                    transition.animate(alongsideTransition: nil) { [weak self] _ in
                        guard let self, keyboardActive, keyboardReady else { return }
                        becomeFirstResponder()
                    }
                } else { becomeFirstResponder() }
            }
        } else { resignFirstResponder(); held.removeAll() }
    }
    func remainingKeys(_ presses: Set<UIPress>, phase: UIPress.Phase) -> Set<UIPress> {
        let settings = ReaderKeys(data: UserDefaults.standard.data(forKey: "reader.keys") ?? Data())
        return presses.filter { press in
            guard let key = press.key else { return true }
            let code = Int(key.keyCode.rawValue)
            if phase == .ended || phase == .cancelled { return held.remove(code) == nil }
            if phase == .changed { return !held.contains(code) }
            guard keyboardReady, let forward = settings.direction(for: ReaderKey(key)) else { return true }
            if held.insert(code).inserted, let keyboardSession {
                keyboardSession.pause("阅读位置改变，已暂停"); turnWithKey(forward)
            }
            return false
        }
    }
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let remaining = remainingKeys(presses, phase: .began)
        if !remaining.isEmpty { super.pressesBegan(remaining, with: event) }
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let remaining = remainingKeys(presses, phase: .ended)
        if !remaining.isEmpty { super.pressesEnded(remaining, with: event) }
    }
    override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let remaining = remainingKeys(presses, phase: .changed)
        if !remaining.isEmpty { super.pressesChanged(remaining, with: event) }
    }
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let remaining = remainingKeys(presses, phase: .cancelled)
        if !remaining.isEmpty { super.pressesCancelled(remaining, with: event) }
    }
}

private struct PhysicalKeyCapture: UIViewRepresentable {
    let captured: (ReaderKey, Bool) -> Void
    func makeUIView(context: Context) -> KeyCaptureSurface { let view = KeyCaptureSurface(); view.captured = captured; return view }
    func updateUIView(_ view: KeyCaptureSurface, context: Context) { view.captured = captured }
    final class KeyCaptureSurface: UIView {
        var captured: ((ReaderKey, Bool) -> Void)?
        override var canBecomeFirstResponder: Bool { true }
        override func didMoveToWindow() { super.didMoveToWindow(); if window != nil { becomeFirstResponder() } }
        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            for press in presses { if let key = press.key, ReaderKey(key).isValid { captured?(ReaderKey(key), true) } }
        }
        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            for press in presses { if let key = press.key { captured?(ReaderKey(key), false) } }
        }
        override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) { pressesEnded(presses, with: event) }
    }
}

struct ReaderKeysView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("reader.keys") private var saved = Data()
    @State private var draft = ReaderKeys()
    @State private var recording: Bool?
    @State private var loaded = false
    var body: some View {
        Form {
            Toggle("启用按键翻页", isOn: $draft.enabled).accessibilityIdentifier("reader-keys-enabled")
            Section {
                Text("连接键盘或发送键盘按键的翻页器，录制上一页和下一页的按键。每个方向可绑定多个按键；长按只翻一页。").font(.caption)
                ForEach([false, true], id: \.self) { forward in
                    Section(forward ? "下一页" : "上一页") {
                        ForEach(draft.bindings.filter { $0.forward == forward }, id: \.key) { binding in
                            HStack {
                                Text(binding.key.label); Spacer()
                                Button("移除", role: .destructive) { draft.bindings.removeAll { $0.key == binding.key } }
                            }
                        }
                        Button("录制按键") { recording = forward }.disabled(draft.bindings.count >= 32)
                            .accessibilityIdentifier(forward ? "record-next-key" : "record-previous-key")
                    }
                }
            }
        }.navigationTitle("按键翻页")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("保存") { saved = draft.encoded(); dismiss() }.accessibilityIdentifier("reader-keys-save") } }
        .onAppear { if !loaded { loaded = true; draft = ReaderKeys(data: saved) } }
        .sheet(isPresented: Binding(get: { recording != nil }, set: { if !$0 { recording = nil } })) {
            if let forward = recording {
                NavigationStack { ReaderKeyCapture(forward: forward, bindings: draft.bindings) { key in draft.bind(key, forward: forward); recording = nil } }
            }
        }
    }
}
private struct ReaderKeyCapture: View {
    let forward: Bool
    let bindings: [ReaderKeyBinding]
    let save: (ReaderKey) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var candidate: ReaderKey?
    @State private var held = false
    var body: some View {
        VStack(spacing: 20) {
            Text("按下键盘或翻页器上的按键；也可同时按住 Shift、Control、Option 或 Command。").font(.callout)
            Text(candidate?.label ?? "等待按键…").font(.largeTitle).accessibilityIdentifier("recorded-key")
            Text(held ? "松开按键后即可保存" : "再按其他键可更换")
            if let candidate, let conflict = bindings.first(where: { $0.key == candidate && $0.forward != forward }) {
                Text("此按键当前用于\(conflict.forward ? "下一页" : "上一页")，保存后改为\(forward ? "下一页" : "上一页")。").foregroundStyle(.orange)
            }
        }.padding().frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
        .background(PhysicalKeyCapture { key, pressed in
            if pressed { candidate = key; held = true }
            else if candidate?.code == key.code { held = false }
        })
        .navigationTitle(forward ? "录制下一页按键" : "录制上一页按键")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("保存") { if let candidate { save(candidate) } }.disabled(candidate == nil || held).accessibilityIdentifier("record-key-save") }
        }
    }
}
