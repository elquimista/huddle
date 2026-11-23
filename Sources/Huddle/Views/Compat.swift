import AppKit
import Perception
import SwiftUI

// What this build needs to run on macOS 13: SwiftUI's newer pieces, with macOS 13 stand-ins.
// On macOS 14 and later each one is SwiftUI's own, so the app there is as it is on main.

// MARK: - Empty states

/// `ContentUnavailableView` (macOS 14), with a likeness of it on macOS 13.
struct EmptyState<LabelContent: View, Description: View, Actions: View>: View {
    let label: LabelContent
    let description: Description
    let actions: Actions

    init(@ViewBuilder label: () -> LabelContent,
         @ViewBuilder description: () -> Description,
         @ViewBuilder actions: () -> Actions) {
        self.label = label()
        self.description = description()
        self.actions = actions()
    }

    var body: some View {
        if #available(macOS 14, *) {
            ContentUnavailableView { label } description: { description } actions: { actions }
        } else {
            VStack(spacing: 10) {
                label
                    .labelStyle(EmptyStateLabelStyle())
                description
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
                actions
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

extension EmptyState where Actions == EmptyView {
    init(@ViewBuilder label: () -> LabelContent, @ViewBuilder description: () -> Description) {
        self.init(label: label, description: description, actions: { EmptyView() })
    }
}

extension EmptyState where LabelContent == Label<Text, Image>, Description == Text?, Actions == EmptyView {
    init(_ title: String, systemImage: String, description: Text? = nil) {
        self.init(label: { Label(title, systemImage: systemImage) }, description: { description }, actions: { EmptyView() })
    }
}

/// No results for a search, as `ContentUnavailableView.search(text:)` says it.
struct SearchEmptyState: View {
    let text: String

    var body: some View {
        if #available(macOS 14, *) {
            ContentUnavailableView.search(text: text)
        } else {
            EmptyState(text.isEmpty ? "No Results" : "No Results for “\(text)”", systemImage: "magnifyingglass",
                       description: Text("Check the spelling or try a new search."))
        }
    }
}

private struct EmptyStateLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 10) {
            configuration.icon
                .font(.system(size: 40, weight: .regular))
                .foregroundColor(.secondary)
            configuration.title
                .font(.title2.weight(.bold))
        }
    }
}

// MARK: - Watching values

extension View {
    /// `onChange(of:initial:_:)` (macOS 14), with no values.
    func onChanged<V: Equatable>(of value: V, initial: Bool = false, _ action: @escaping () -> Void) -> some View {
        modifier(OnChanged(value: value, initial: initial) { _, _ in action() })
    }

    /// `onChange(of:initial:_:)` (macOS 14), with the value before and the value now.
    func onChanged<V: Equatable>(of value: V, initial: Bool = false, _ action: @escaping (V, V) -> Void) -> some View {
        modifier(OnChanged(value: value, initial: initial, action: action))
    }
}

private struct OnChanged<V: Equatable>: ViewModifier {
    let value: V
    let initial: Bool
    let action: (V, V) -> Void

    func body(content: Content) -> some View {
        if #available(macOS 14, *) {
            content.onChange(of: value, initial: initial) { old, new in action(old, new) }
        } else {
            // The value this body was drawn with is the one before the change.
            content
                .onChange(of: value) { [value] new in action(value, new) }
                .onAppear { if initial { action(value, value) } }
        }
    }
}

// MARK: - Keys

/// What a key handler did with a key: as `KeyPress.Result` (macOS 14).
enum KeyResult {
    case handled, ignored
}

extension View {
    /// `onKeyPress(_:phases:action:)` (macOS 14) for a key going down while this view, or the
    /// field in it, has the keyboard (`focused`). On macOS 13, AppKit's key events are watched
    /// while it does, and one handled goes no further.
    func onKeyDown(_ key: KeyEquivalent, focused: Bool,
                   action: @escaping (EventModifiers) -> KeyResult) -> some View {
        modifier(KeyDown(key: key, focused: focused, action: action))
    }
}

private struct KeyDown: ViewModifier {
    let key: KeyEquivalent
    let focused: Bool
    let action: (EventModifiers) -> KeyResult
    @State private var watcher = KeyWatcher()

    func body(content: Content) -> some View {
        if #available(macOS 14, *) {
            content.onKeyPress(key, phases: .down) { press in
                action(press.modifiers) == .handled ? .handled : .ignored
            }
        } else {
            // The newest handler, for the watcher to call: one from an earlier drawing would see
            // the view as it was then.
            let _ = watcher.update(key: key, action: action)
            content
                .onAppear { watcher.watch(focused) }
                .onChange(of: focused) { watcher.watch($0) }
                .onDisappear { watcher.watch(false) }
        }
    }
}

/// Watches key presses while a field has the keyboard (macOS 13).
private final class KeyWatcher {
    private var monitor: Any?
    private var key: KeyEquivalent = .return
    private var action: ((EventModifiers) -> KeyResult)?

    func update(key: KeyEquivalent, action: @escaping (EventModifiers) -> KeyResult) {
        self.key = key
        self.action = action
    }

    func watch(_ on: Bool) {
        if on, monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, Self.matches(event, self.key), let action = self.action else { return event }
                return action(Self.modifiers(of: event)) == .handled ? nil : event
            }
        } else if !on, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    private static func matches(_ event: NSEvent, _ key: KeyEquivalent) -> Bool {
        // By their characters: KeyEquivalent itself is Equatable only from macOS 14, and comparing
        // two of them here, on 13, crashes.
        switch key.character {
        case KeyEquivalent.return.character: return event.keyCode == 36 || event.keyCode == 76
        case KeyEquivalent.escape.character: return event.keyCode == 53
        case KeyEquivalent.tab.character: return event.keyCode == 48
        case KeyEquivalent.upArrow.character: return event.keyCode == 126
        case KeyEquivalent.downArrow.character: return event.keyCode == 125
        case KeyEquivalent.leftArrow.character: return event.keyCode == 123
        case KeyEquivalent.rightArrow.character: return event.keyCode == 124
        default: return event.charactersIgnoringModifiers == String(key.character)
        }
    }

    private static func modifiers(of event: NSEvent) -> EventModifiers {
        var modifiers: EventModifiers = []
        let flags = event.modifierFlags
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.control) { modifiers.insert(.control) }
        return modifiers
    }
}

// MARK: - Where a view is in a scroll view

/// The scroll view's visible area in a view's own coordinates, as `bounds(of: .scrollView)`
/// (macOS 14) gives it. On macOS 13, worked out from where the view is in the scroll view's
/// named coordinate space (`ScrollSpace.name`, set on the scroll view) and the scroll view's size.
enum ScrollSpace {
    static let name = "huddle.scrollView"

    static func visibleBounds(_ proxy: GeometryProxy, viewport: CGSize) -> CGRect? {
        if #available(macOS 14, *) { return proxy.bounds(of: .scrollView) }
        guard viewport.width > 0, viewport.height > 0 else { return nil }
        let frame = proxy.frame(in: .named(name))
        return CGRect(x: -frame.minX, y: -frame.minY, width: viewport.width, height: viewport.height)
    }
}

extension EnvironmentValues {
    /// The size of the scroll view a view is in, for `ScrollSpace.visibleBounds` on macOS 13.
    @Entry var scrollViewport: CGSize = .zero
}

/// Gives what's inside the size it has (macOS 13 only: on 14 and later nothing needs it).
struct ViewportReader<Content: View>: View {
    @ViewBuilder let content: (CGSize) -> Content

    var body: some View {
        // Tracked here, where the content is made, not in the body that holds the reader.
        if #available(macOS 14, *) {
            WithPerceptionTracking { content(.zero) }
        } else {
            GeometryReader { geometry in
                WithPerceptionTracking {
                    content(geometry.size)
                        .environment(\.scrollViewport, geometry.size)
                }
            }
        }
    }
}

// MARK: - Stored settings

/// `AppStorage`, with the value also held in the view itself. On macOS 13 a view's content in
/// `WithPerceptionTracking` is drawn again only if what it captured of the view has changed, and
/// an `AppStorage` holds no more than a reference to where its value is kept: a new value would
/// leave the view as it was (Settings showing the old choice, a panel its old width).
@propertyWrapper
struct AppSetting<Value>: DynamicProperty {
    private let storage: AppStorage<Value>
    /// The value as of this drawing, so that one view and the next differ when it changes.
    private var current: Value

    var wrappedValue: Value {
        get { storage.wrappedValue }
        nonmutating set { storage.wrappedValue = newValue }
    }

    var projectedValue: Binding<Value> { storage.projectedValue }

    mutating func update() { current = storage.wrappedValue }
}

extension AppSetting {
    init(wrappedValue: Value, _ key: String) where Value == Bool {
        storage = AppStorage(wrappedValue: wrappedValue, key)
        current = storage.wrappedValue
    }

    init(wrappedValue: Value, _ key: String) where Value == Double {
        storage = AppStorage(wrappedValue: wrappedValue, key)
        current = storage.wrappedValue
    }

    init(wrappedValue: Value, _ key: String) where Value: RawRepresentable, Value.RawValue == String {
        storage = AppStorage(wrappedValue: wrappedValue, key)
        current = storage.wrappedValue
    }
}

// MARK: - Small things

extension View {
    /// A symbol changing in place, as `.contentTransition(.symbolEffect(.replace))` does on macOS 14.
    @ViewBuilder func symbolReplaceTransition() -> some View {
        if #available(macOS 14, *) { contentTransition(.symbolEffect(.replace)) } else { self }
    }

    /// A symbol bouncing as `value` changes, on macOS 14.
    @ViewBuilder func symbolBounce<V: Equatable>(value: V) -> some View {
        if #available(macOS 14, *) { symbolEffect(.bounce, value: value) } else { self }
    }

    /// Where a scroll view starts, on macOS 14. On macOS 13 it starts at the top, and the
    /// timeline's own jump to its newest message takes it there.
    @ViewBuilder func startsScrolled(at anchor: UnitPoint?) -> some View {
        if #available(macOS 14, *) { defaultScrollAnchor(anchor) } else { self }
    }

    /// No focus ring, on macOS 14.
    @ViewBuilder func noFocusEffect() -> some View {
        if #available(macOS 14, *) { focusEffectDisabled() } else { self }
    }

    /// A list row that can be dragged, on macOS 14. On macOS 13 a draggable row (`draggable` or
    /// `onDrag` alike) takes the click meant to select it, so there it can't be dragged: its menu
    /// moves it instead.
    @ViewBuilder func listRowDraggable<T: Transferable, Preview: View>(_ payload: T, @ViewBuilder preview: () -> Preview) -> some View {
        if #available(macOS 14, *) { draggable(payload, preview: preview) } else { self }
    }
}

/// `Section(isExpanded:content:header:)` (macOS 14). On macOS 13 the sidebar folds sections
/// itself, without a say from the app, so there it's a plain section.
struct FoldingSection<Content: View, Header: View>: View {
    let isExpanded: Binding<Bool>
    @ViewBuilder let content: () -> Content
    @ViewBuilder let header: () -> Header

    var body: some View {
        if #available(macOS 14, *) {
            Section(isExpanded: isExpanded) { content() } header: { header() }
        } else {
            Section { content() } header: { header() }
        }
    }
}

/// `withAnimation(_:completionCriteria:_:completion:)` (macOS 14). On macOS 13, the completion
/// runs once the animation has had time to finish.
@MainActor
func withAnimationThen(_ animation: Animation?, untilRemoved: Bool = false, settle: TimeInterval = 0.45,
                       _ body: () -> Void, completion: @escaping () -> Void) {
    if #available(macOS 14, *) {
        withAnimation(animation, completionCriteria: untilRemoved ? .removed : .logicallyComplete, body, completion: completion)
    } else {
        withAnimation(animation, body)
        DispatchQueue.main.asyncAfter(deadline: .now() + settle, execute: completion)
    }
}

extension NSApplication {
    /// Comes to the front: `activate()` on macOS 14, which asks politely, and the older way before.
    func activateApp() {
        if #available(macOS 14, *) { activate() } else { activate(ignoringOtherApps: true) }
    }
}
