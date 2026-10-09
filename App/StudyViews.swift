import SwiftUI
import WLCore

/// Both saved lessons and manual snapshots browse the same source-linked tree.
struct StudyOutlineView: View {
    let nodes: [StudyNode]
    let sources: [StudySource]
    let jump: ([UUID]) -> Void
    @State private var collapsed = Set<String>()
    private var allIDs: Set<String> { Set(StudyTree.flatten(nodes).map(\.id)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(nodes.count) 个主题").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { collapsed = collapsed.isEmpty ? allIDs : [] } label: {
                    Image(systemName: collapsed.isEmpty ? "chevron.up.chevron.down" : "chevron.down")
                        .frame(minWidth: 44, minHeight: 44)
                }.accessibilityLabel(collapsed.isEmpty ? "全部折叠" : "全部展开")
            }
            ForEach(nodes) { node in
                StudySummaryNode(node: node, depth: 0, sources: sources, collapsed: $collapsed, jump: jump)
            }
        }.onChange(of: nodes) { _, _ in collapsed.formIntersection(allIDs) }
    }
}

private struct StudySummaryNode: View {
    let node: StudyNode
    let depth: Int
    let sources: [StudySource]
    @Binding var collapsed: Set<String>
    let jump: ([UUID]) -> Void
    private var expanded: Bool { !collapsed.contains(node.id) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Button {
                    if expanded { collapsed.insert(node.id) } else { collapsed.remove(node.id) }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption2)
                            .foregroundStyle(Color.williamSecondary).frame(width: 10)
                        Text(node.title).font(depth == 0 ? .headline : .subheadline.weight(.medium))
                            .foregroundStyle(.primary).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }.frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityValue(expanded ? "已展开" : "已折叠")
                    .accessibilityIdentifier("summary-toggle-\(node.id)")
                StudySourceButton(node: node, sources: sources, prefix: "summary", jump: jump)
            }
            if expanded {
                if !node.body.isEmpty {
                    Text(node.body).font(.body).lineSpacing(6).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 20)
                        .accessibilityIdentifier("summary-body-\(node.id)")
                }
                ForEach(node.children) { child in
                    StudySummaryNode(node: child, depth: depth + 1, sources: sources, collapsed: $collapsed, jump: jump)
                        .padding(.leading, 16)
                }
            }
        }.padding(.vertical, depth == 0 ? 8 : 2)
    }
}

private struct StudySourceButton: View {
    let node: StudyNode
    let sources: [StudySource]
    let prefix: String
    let jump: ([UUID]) -> Void
    private var matches: [StudySource] { sources.filter { node.segmentIDs.contains($0.id) } }
    var body: some View {
        if let first = matches.first {
            Button { jump([first.id]) } label: {
                HStack(spacing: 4) {
                    Text(SessionStore.readingTime(first.offset)).monospacedDigit()
                    Image(systemName: "arrow.up.forward.square")
                }.font(.caption).frame(minWidth: 44, minHeight: 44)
            }.buttonStyle(.plain).foregroundStyle(Color.williamSecondary)
                .accessibilityLabel("查看原文，\(SessionStore.readingTime(first.offset))")
                .accessibilityIdentifier("\(prefix)-source-\(node.id)")
                .contextMenu {
                    ForEach(matches) { source in
                        Button { jump([source.id]) } label: { Text(SessionStore.readingTime(source.offset)) }
                    }
                }
        }
    }
}

struct StudyMapView: View {
    let title: String
    let nodes: [StudyNode]
    let sources: [StudySource]
    var height: CGFloat = 380
    let jump: ([UUID]) -> Void
    @State private var collapsed = Set<String>()
    @State private var inspected: StudyNode?
    @State private var scale = 0.8
    @State private var baseScale = 0.8
    @State private var diagramSize = CGSize(width: 600, height: 400)
    @State private var reset = 0
    @State private var fullScreen = false
    @State private var fullScreenJump: [UUID]?
    var allowsFullScreen = true
    private var branches: Set<String> { Set(StudyTree.flatten(nodes).filter { !$0.children.isEmpty }.map(\.id)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                Button { zoom(scale - 0.2) } label: { Image(systemName: "minus.magnifyingglass").frame(width: 44, height: 44) }.accessibilityLabel("缩小")
                Text("\(Int((scale * 100).rounded()))%").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .frame(minWidth: 38).accessibilityIdentifier("map-scale")
                Button { zoom(scale + 0.2) } label: { Image(systemName: "plus.magnifyingglass").frame(width: 44, height: 44) }.accessibilityLabel("放大")
                Spacer(minLength: 0)
                Button { collapsed = collapsed.isEmpty ? branches : [] } label: {
                    Image(systemName: collapsed.isEmpty ? "rectangle.compress.vertical" : "rectangle.expand.vertical").frame(width: 44, height: 44)
                }.accessibilityLabel(collapsed.isEmpty ? "折叠导图" : "展开导图")
                Button { zoom(0.8); reset += 1 } label: { Image(systemName: "arrow.counterclockwise").frame(width: 44, height: 44) }
                    .accessibilityLabel("重置导图")
                if allowsFullScreen {
                    Button { fullScreen = true } label: { Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 44, height: 44) }
                        .accessibilityLabel("全屏导图")
                }
            }.buttonStyle(.plain).foregroundStyle(Color.williamAccent)
            ScrollView([.horizontal, .vertical]) {
                LessonMindMap(title: title, nodes: nodes, sources: sources, collapsed: collapsed,
                              inspect: { inspected = $0 }, toggle: { id in
                    if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
                }, jump: jump)
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { _, size in diagramSize = size }
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: diagramSize.width * scale, height: diagramSize.height * scale, alignment: .topLeading)
                    .padding(16)
            }.id(reset).defaultScrollAnchor(.topLeading).frame(height: height)
                .background(Color(uiColor: .secondarySystemBackground).opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
                .simultaneousGesture(MagnifyGesture().onChanged { value in
                    scale = min(2, max(0.4, baseScale * value.magnification))
                }.onEnded { _ in baseScale = scale })
                .accessibilityIdentifier("study-map-canvas")
        }
        .sheet(item: $inspected) { node in
            StudyNodeDetail(node: node, sources: sources) { ids in
                inspected = nil
                jump(ids)
            }
        }
        .fullScreenCover(isPresented: $fullScreen, onDismiss: {
            if let ids = fullScreenJump { fullScreenJump = nil; jump(ids) }
        }) {
            NavigationStack {
                GeometryReader { geometry in
                    StudyMapView(title: title, nodes: nodes, sources: sources,
                        height: max(200, geometry.size.height - 70), jump: { ids in fullScreenJump = ids; fullScreen = false }, allowsFullScreen: false)
                        .padding(.horizontal, 16)
                }.navigationTitle("思维导图").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { fullScreen = false } } }
            }
        }
        .onChange(of: nodes) { _, _ in
            let all = StudyTree.flatten(nodes)
            collapsed.formIntersection(Set(all.map(\.id)))
            if let id = inspected?.id { inspected = all.first { $0.id == id } }
        }
    }
    private func zoom(_ value: Double) { scale = min(2, max(0.4, value)); baseScale = scale }
}

private struct StudyNodeDetail: View {
    @Environment(\.dismiss) private var dismiss
    let node: StudyNode
    let sources: [StudySource]
    let jump: ([UUID]) -> Void
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !node.body.isEmpty { Text(node.body).font(.body).lineSpacing(6).textSelection(.enabled) }
                    ForEach(node.children) { child in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(child.title).font(.headline)
                            if !child.body.isEmpty { Text(child.body).lineSpacing(6).textSelection(.enabled) }
                        }
                    }
                    Divider()
                    Text("原文").font(.caption).foregroundStyle(.secondary)
                    ForEach(sources.filter { node.segmentIDs.contains($0.id) }) { source in
                        Button { jump([source.id]) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Label(SessionStore.readingTime(source.offset), systemImage: "arrow.up.forward.square").font(.caption)
                                Text(source.english).font(.body).foregroundStyle(.primary).multilineTextAlignment(.leading)
                            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }.buttonStyle(.plain).accessibilityIdentifier("node-source-\(source.id)")
                    }
                }.frame(maxWidth: 720, alignment: .leading).padding(24).frame(maxWidth: .infinity)
            }.navigationTitle(node.title).navigationBarTitleDisplayMode(.inline)
                .accessibilityIdentifier("map-detail-\(node.id)")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
}

private struct StudyMapBounds: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] { [:] }
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Also used for image export; exporting always includes every branch.
struct LessonMindMap: View {
    let title: String
    let nodes: [StudyNode]
    var sources: [StudySource] = []
    var collapsed: Set<String> = []
    var inspect: ((StudyNode) -> Void)?
    var toggle: ((String) -> Void)?
    let jump: ([UUID]) -> Void
    private var links: [(String, String)] {
        func walk(_ nodes: [StudyNode], parent: String) -> [(String, String)] {
            nodes.flatMap { node in
                [(parent, "n-\(node.id)")] + (collapsed.contains(node.id) ? [] : walk(node.children, parent: "n-\(node.id)"))
            }
        }
        return walk(nodes, parent: "root")
    }
    var body: some View {
        HStack(alignment: .center, spacing: 36) {
            Text(title).font(.headline).multilineTextAlignment(.center).frame(width: 140).padding(14)
                .background(Color.williamAccent.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
                .anchorPreference(key: StudyMapBounds.self, value: .bounds) { ["root": $0] }
            VStack(alignment: .leading, spacing: 28) {
                ForEach(nodes) { node in
                    MindMapBranch(node: node, sources: sources, collapsed: collapsed, inspect: inspect, toggle: toggle, jump: jump)
                }
            }
        }.fixedSize(horizontal: true, vertical: true)
            .backgroundPreferenceValue(StudyMapBounds.self) { bounds in
                GeometryReader { geometry in
                    Path { path in
                        for (parent, child) in links {
                            if let from = bounds[parent], let to = bounds[child] {
                                let a = geometry[from], b = geometry[to]
                                let start = CGPoint(x: a.maxX, y: a.midY), end = CGPoint(x: b.minX, y: b.midY)
                                let middle = (start.x + end.x) / 2
                                path.move(to: start)
                                path.addCurve(to: end, control1: CGPoint(x: middle, y: start.y), control2: CGPoint(x: middle, y: end.y))
                            }
                        }
                    }.stroke(Color.williamAccent.opacity(0.25), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
                }.allowsHitTesting(false)
            }
    }
}

private struct MindMapBranch: View {
    let node: StudyNode
    let sources: [StudySource]
    let collapsed: Set<String>
    let inspect: ((StudyNode) -> Void)?
    let toggle: ((String) -> Void)?
    let jump: ([UUID]) -> Void
    var body: some View {
        HStack(alignment: .center, spacing: 36) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    Button { inspect?(node) } label: {
                        Text(node.title).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                            .multilineTextAlignment(.leading).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }.buttonStyle(.plain).accessibilityLabel("查看节点，\(node.title)").accessibilityIdentifier("map-node-\(node.id)")
                    if !node.children.isEmpty, let toggle {
                        Button { toggle(node.id) } label: {
                            Image(systemName: collapsed.contains(node.id) ? "plus" : "minus").font(.caption)
                                .frame(width: 44, height: 44)
                        }.buttonStyle(.plain).accessibilityLabel(collapsed.contains(node.id) ? "展开\(node.title)" : "折叠\(node.title)")
                            .accessibilityIdentifier("map-toggle-\(node.id)")
                    }
                }
                if inspect != nil { StudySourceButton(node: node, sources: sources, prefix: "map", jump: jump) }
            }.padding(.horizontal, 12).padding(.vertical, 8).frame(width: 190)
                .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.williamAccent.opacity(0.16), lineWidth: 1) }
                .anchorPreference(key: StudyMapBounds.self, value: .bounds) { ["n-\(node.id)": $0] }
            if !collapsed.contains(node.id), !node.children.isEmpty {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(node.children) { child in
                        MindMapBranch(node: child, sources: sources, collapsed: collapsed, inspect: inspect, toggle: toggle, jump: jump)
                    }
                }
            }
        }
    }
}
