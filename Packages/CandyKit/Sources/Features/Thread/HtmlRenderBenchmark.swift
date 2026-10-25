#if DEBUG
import AppKit
import DesignSystem
import Foundation
import T3Protocol
import T3Store

/// Opt-in sandbox driver. Runs the real thread or Conductor view; never sends orchestration commands.
@MainActor
public final class HtmlRenderBenchmark: DSView {
    struct Manifest: Decodable {
        struct Workload: Decodable { var pages: [Page] }
        struct Page: Decodable { var attachmentId: String; var title: String; var height: Double; var url: URL }
        var cases: [String: Workload]
    }
    private let pages: [Manifest.Page]
    private let mode: String
    private let output: URL
    private let log: FileHandle
    private let panel: ThreadPanelView?
    private let conductor: OrchestratorPaneView?
    private let origin = ProcessInfo.processInfo.systemUptime
    private var started = false
    private var phase = "setup"
    private var live: [String: WeakFrame] = [:]
    private var seen: Set<String> = []
    private var painted: Set<String> = []
    private struct WeakFrame { weak var value: ThreadWebFrameView? }

    public init(manifestPath: String, kind: String, mode: String, output: String) throws {
        let sandbox = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("CandyWrapper-research/sandbox").resolvingSymlinksInPath().path + "/"
        guard URL(fileURLWithPath: manifestPath).resolvingSymlinksInPath().path.hasPrefix(sandbox),
              URL(fileURLWithPath: output).resolvingSymlinksInPath().path.hasPrefix(sandbox), ["thread", "conductor"].contains(mode) else {
            throw CocoaError(.fileReadNoPermission)
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: URL(fileURLWithPath: manifestPath)))
        guard let workload = manifest.cases[kind], workload.pages.count == 10,
              workload.pages.allSatisfy({ $0.url.host == "127.0.0.1" && $0.url.port == 47391 }) else { throw CocoaError(.fileReadCorruptFile) }
        pages = workload.pages; self.mode = mode; self.output = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: self.output, withIntermediateDirectories: true)
        let path = self.output.appendingPathComponent("events.jsonl")
        FileManager.default.createFile(atPath: path.path, contents: nil)
        log = try FileHandle(forWritingTo: path)
        panel = mode == "thread" ? ThreadPanelView() : nil
        conductor = mode == "conductor" ? OrchestratorPaneView() : nil
        super.init(frame: .zero)
        let urls = Dictionary(uniqueKeysWithValues: pages.map { ($0.attachmentId, $0.url) })
        let asset: @MainActor @Sendable (String, String) async -> URL? = { id, _ in urls[id] }
        panel?.model.webAssetURL = asset
        conductor?.webAssetURL = asset
        addSubview(panel ?? conductor!)
        ThreadWebFrameView.benchmarkObserver = { [weak self] event, page, frame, data in
            self?.observe(event, page: page, frame: frame, data: data)
        }
        record("setup", ["mode":mode,"kind":kind,"pid":ProcessInfo.processInfo.processIdentifier,"originUptime":origin])
    }
    required init?(coder: NSCoder) { fatalError() }

    override public func layout() { super.layout(); (panel ?? conductor!).frame = bounds }
    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !started else { return }; started = true
        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(2))
            await self.run()
        }
    }
    private func record(_ event: String, _ values: [String: Any] = [:]) {
        var v = values; v["event"] = event; v["phase"] = phase
        v["ms"] = (ProcessInfo.processInfo.systemUptime - origin) * 1000
        guard let data = try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys]) else { return }
        try? log.write(contentsOf: data + Data([10]))
    }
    private func observe(_ event: String, page: ThreadWebFrameView.Page, frame: ThreadWebFrameView, data: JSONValue?) {
        let title = page.title
        if event == "activate" { live[title] = WeakFrame(value: frame); seen.insert(title) }
        if event == "release" { live[title] = nil; painted.remove(title) }
        var values: [String: Any] = ["page":title,"width":frame.bounds.width,"height":frame.bounds.height,"live":live.count]
        if let data {
            guard HtmlRenderTheme.contentHeight(data) != nil || data["benchmark"]?.stringValue != nil else { return }
            values["message"] = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(data))) ?? [:]
        }
        record(event, values)
        if data?["benchmark"]?.stringValue == "paint-opportunity" {
            painted.insert(title)
            // The page reached two rAFs after image decode. This next native turn records the applied frame height.
            DispatchQueue.main.async { [weak self, weak frame] in
                guard let self, let frame else { return }
                self.window?.contentView?.layoutSubtreeIfNeeded()
                self.record("native-layout", ["page":title,"height":frame.bounds.height,"width":frame.bounds.width])
            }
        }
    }
    private func projection(_ count: Int) throws -> ThreadProjection {
        let stamp = "2026-10-25T12:00:00.000Z"
        var p = try JSONDecoder().decode(ThreadProjection.self, from: Data("{\"thread\":{\"id\":\"html-benchmark\",\"title\":\"HTML benchmark\"},\"updatedAt\":\"\(stamp)\"}".utf8))
        for (i, page) in pages.prefix(count).enumerated() {
            let obj: [String: Any] = ["id":"html-item-\(i)","threadId":"html-benchmark","type":"dynamic_tool","ordinal":i,"status":"completed","updatedAt":stamp,
                "toolName":"html_render","output":["htmlRender":["attachmentId":page.attachmentId,"title":page.title,"height":page.height]]]
            let item = try JSONDecoder().decode(TurnItem.self, from: JSONSerialization.data(withJSONObject: obj))
            p.turnItems.append(item); p.visibleTurnItems.append(ProjectedTurnItem(local:item,position:i))
        }
        return p
    }
    private func arrive(_ count: Int) throws {
        record("arrival", ["page":pages[count-1].title,"count":count])
        if let panel { panel.setProjection(try projection(count), projectTitle:"Sandbox", workspaceRoot:output.deletingLastPathComponent().path) }
        if let conductor {
            var state = OrchestratorPaneState(); state.name = "Conductor"; state.started = true; state.connected = true
            state.machine = "HTML sandbox"; state.environmentId = "html-benchmark"
            state.items = pages.prefix(count).map { .html(id:$0.attachmentId,page:HtmlRenderReference(attachmentId:$0.attachmentId,title:$0.title,height:$0.height)) }
            conductor.set(state)
        }
        window?.contentView?.layoutSubtreeIfNeeded()
    }
    private func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(descendants) }
    private var scroll: NSScrollView? {
        if let panel { return panel.timeline.scrollView }
        return descendants(self).compactMap { $0 as? NSScrollView }.filter { !$0.isHiddenOrHasHiddenAncestor }.max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
    }
    private func visit(_ fraction: Double, label: String) async {
        guard let scroll, let doc = scroll.documentView else { record("missing-scroll"); return }
        let maxY = max(0, doc.frame.height - scroll.contentView.bounds.height)
        let y = maxY * fraction
        record("scroll", ["label":label,"fraction":fraction,"y":y,"documentHeight":doc.frame.height])
        scroll.contentView.scroll(to:NSPoint(x:0,y:y)); scroll.reflectScrolledClipView(scroll.contentView)
        window?.contentView?.layoutSubtreeIfNeeded()
        let visitStart = ProcessInfo.processInfo.systemUptime
        for (title, weakFrame) in live where painted.contains(title) {
            guard let frame = weakFrame.value, let web = frame.webView, !frame.isHiddenOrHasHiddenAncestor,
                  frame.convert(frame.bounds, to:scroll.contentView).intersects(scroll.contentView.bounds) else { continue }
            record("resident-at-scroll", ["page":title,"label":label,"height":frame.bounds.height])
            web.takeSnapshot(with:nil) { [weak self] image, error in
                guard let self else { return }
                self.record("resident-snapshot", ["page":title,"label":label,"snapshotMs":(ProcessInfo.processInfo.systemUptime-visitStart)*1000,"success":image != nil,"error":error.map(String.init(describing:)) ?? ""])
            }
        }
        try? await Task.sleep(for:.seconds(2))
        var visible: [[String:Any]] = []
        for frame in descendants(self).compactMap({ $0 as? ThreadWebFrameView }) {
            let rect = frame.convert(frame.bounds, to:scroll.contentView)
            if rect.intersects(scroll.contentView.bounds), !frame.isHiddenOrHasHiddenAncestor {
                let title = live.first(where: { $0.value.value === frame })?.key ?? "evicted"
                visible.append(["page":title,"live":frame.isLive,"height":frame.bounds.height])
            }
        }
        record("viewport", ["label":label,"frames":visible,"budgetCount":ThreadWebFrameBudget.count])
        screenshot(label)
    }
    private func screenshot(_ label: String) {
        // AppKit's layer export omits remote WebKit surfaces. The runner captures the real screen at these markers.
        record("capture", ["label":label])
    }
    private func run() async {
        phase = "arrival"
        for count in 1...pages.count {
            do { try arrive(count) } catch { record("error",["description":String(describing:error)]); NSApp.terminate(nil); return }
            try? await Task.sleep(for:.seconds(2))
        }
        record("arrival-done", ["live":live.count,"seen":seen.sorted()])
        phase = "back"
        for i in (0...9).reversed() { await visit(Double(i)/9,label:"back-\(i+1)") }
        phase = "return"
        for i in 0...9 { await visit(Double(i)/9,label:"return-\(i+1)") }
        phase = "done"; record("done",["live":live.count,"seen":seen.sorted()])
        ThreadWebFrameView.benchmarkObserver = nil
        try? await Task.sleep(for:.seconds(1))
        NSApp.terminate(nil)
    }
}
#endif
