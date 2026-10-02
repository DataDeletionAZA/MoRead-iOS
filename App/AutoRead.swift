import SwiftUI
import UIKit
import MoReadCore

@MainActor
final class AutoReadSession: ObservableObject {
    enum Phase: Equatable { case off, preparing, running, paused(String) }
    enum Result: Equatable { case waiting, ready, moved, end }
    @Published private(set) var phase: Phase = .off
    private(set) var settings = AutoReadSettings()
    var engaged: Bool { phase == .preparing || phase == .running }
    var label: String {
        switch phase {
        case .off: return "自动阅读"
        case .preparing: return "正在准备…"
        case .running: return "自动阅读中"
        case .paused(let reason): return reason
        }
    }
    private var owner: UUID?
    private var advance: ((Double) async -> Result)?
    private var link: CADisplayLink?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var clock = AutoReadClock()
    private var waitingSince: TimeInterval?
    private var operationStarted: TimeInterval?
    private var previousIdleState: Bool?

    func attach(_ owner: UUID, advance: @escaping (Double) async -> Result) {
        self.owner = owner; self.advance = advance
    }
    func detach(_ owner: UUID) {
        guard self.owner == owner else { return }
        self.owner = nil; advance = nil
        generation = UUID(); task?.cancel(); task = nil; operationStarted = nil; clock.reset()
        if engaged { waitingSince = CACurrentMediaTime() }
    }
    func start(_ settings: AutoReadSettings) {
        cancel()
        self.settings = settings.validated(); phase = .preparing
        waitingSince = CACurrentMediaTime()
        previousIdleState = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        let link = CADisplayLink(target: FrameTarget(self), selector: #selector(FrameTarget.tick(_:)))
        link.preferredFrameRateRange = settings.mode == .scroll
            ? CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            : CAFrameRateRange(minimum: 10, maximum: 10, preferred: 10)
        self.link = link; link.add(to: .main, forMode: .common)
    }
    func pause(_ reason: String = "已暂停") {
        guard engaged else { return }
        cancel(); phase = .paused(reason)
    }
    func stop() { cancel(); phase = .off }
    private func cancel() {
        generation = UUID(); task?.cancel(); task = nil
        link?.invalidate(); link = nil; clock.reset(); waitingSince = nil; operationStarted = nil
        if let previousIdleState { UIApplication.shared.isIdleTimerDisabled = previousIdleState; self.previousIdleState = nil }
    }
    private func tick(_ timestamp: TimeInterval) {
        guard engaged else { return }
        if let operationStarted, timestamp - operationStarted >= 30 { pause("正文暂不可用，已暂停"); return }
        if let waitingSince, timestamp - waitingSince >= 30 { pause("正文暂不可用，已暂停"); return }
        guard task == nil, let advance else { return }
        operationStarted = timestamp
        let token = generation
        let amount = phase == .running ? clock.step(at: timestamp, settings: settings) : 0
        task = Task { [weak self] in
            let result = await advance(amount)
            guard let self, !Task.isCancelled, generation == token else { return }
            task = nil; operationStarted = nil
            switch result {
            case .waiting:
                if waitingSince == nil { waitingSince = CACurrentMediaTime() }
                clock.reset(); if phase != .preparing { phase = .preparing }
            case .ready, .moved:
                waitingSince = nil
                if phase != .running { clock.reset(); phase = .running }
                if result == .moved { clock.pageCommitted(at: CACurrentMediaTime()) }
            case .end: pause("已到全书末尾")
            }
        }
    }
    @MainActor private final class FrameTarget: NSObject {
        weak var session: AutoReadSession?
        init(_ session: AutoReadSession) { self.session = session }
        @objc func tick(_ link: CADisplayLink) { session?.tick(link.timestamp) }
    }
}

/// Observes initial contact without taking touches away from selection or page gestures.
final class AutoReadTouch: UIGestureRecognizer {
    private let session: AutoReadSession
    init(_ session: AutoReadSession) {
        self.session = session; super.init(target: nil, action: nil)
        cancelsTouchesInView = false; delaysTouchesBegan = false; delaysTouchesEnded = false
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        session.pause("触摸后已暂停"); state = .failed
    }
}

struct AutoReadSettingsView: View {
    @State var settings: AutoReadSettings
    let speechActive: Bool
    let start: (AutoReadSettings) -> Void
    var body: some View {
        Form {
            Picker("自动阅读方式", selection: $settings.mode) {
                Text("匀速滚动").tag(AutoReadSettings.Mode.scroll)
                Text("定时翻页").tag(AutoReadSettings.Mode.page)
            }.accessibilityIdentifier("auto-read-mode")
            if settings.mode == .scroll {
                LabeledContent("滚动速度", value: String(format: "%.1f ×", settings.speed / 24))
                Slider(value: $settings.speed, in: 8...96, step: 1).accessibilityLabel("滚动速度")
                Toggle("导读线", isOn: $settings.showGuide)
            } else {
                Stepper("每 \(Int(settings.interval)) 秒翻页", value: $settings.interval, in: 3...120, step: 1).accessibilityIdentifier("auto-read-interval")
            }
            Section {
                Button("开始自动阅读") { start(settings.validated()) }.disabled(speechActive).accessibilityIdentifier("auto-read-start")
                if speechActive { Text("请先暂停听书。").foregroundStyle(.secondary) }
            } footer: { Text("触摸正文、打开面板、切到后台或开始听书后会暂停。点击继续才会恢复。") }
        }.navigationTitle("自动阅读")
    }
}
