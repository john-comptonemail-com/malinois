//
//  MainActorBuilders.swift
//  Malinois
//
//  Loops, geometry readers and timelines whose content is built on the main thread, though SwiftUI may ask for it on
//  its background render thread (item 246).
//
//  While an animation runs, SwiftUI may build a loop's rows, a geometry reader's content or a timeline's next page on
//  its background render thread (Apple's FB20692404). A closure written in a view is main-actor code, and Swift 6
//  stops the app at its first line when it runs anywhere else: the crash of 1.12 (87) at PIN setup on an iPhone 16,
//  in the PIN pad's row of keys. So the closures handed to SwiftUI here are `@Sendable`, which makes them belong to no
//  actor and lets Swift prove they touch nothing of the main thread's: each only makes a `BuiltOnMain` that carries
//  its item. The item's content, which may read the screen's state and call its methods, is built in that view's
//  body, which SwiftUI evaluates on the main thread. A builder that shows its item through SwiftUI's own views only
//  can be `@Sendable` itself, as the pickers' are, and a fixed list needs no loop, as the PIN pad's keys. The rule is
//  held by MalinoisTests' Item246RoundUTests over the whole app's code.
//

import SwiftUI

/// The content of one item of a loop, a geometry reader or a timeline, built on the main thread (item 246).
///
/// It may be made on any thread, so it carries only the item, which is `Sendable`, and the main-actor closure that
/// builds the item's content; `body`, which SwiftUI evaluates on the main thread, calls that closure. The content is
/// type-erased so that the closures that make this view, which may run on any thread, use no generic view type.
nonisolated struct BuiltOnMain<Input: Sendable>: View {
    let input: Input
    let content: @MainActor (Input) -> AnyView

    @MainActor var body: some View { content(input) }
}

/// A `ForEach` whose rows are built on the main thread (item 246): the same data, identity and rows, for rows that read
/// the screen's state or call its methods. `ForEach` itself stays for rows built from their item through SwiftUI's own
/// views alone, with a `@Sendable` builder.
struct MainActorForEach<Data: RandomAccessCollection, ID: Hashable, Content: View>: View where Data.Element: Sendable {
    let data: Data
    let id: KeyPath<Data.Element, ID>
    let content: @MainActor (Data.Element) -> Content

    /// Rows for `data`, each identified by `id` and built by `content` on the main thread.
    init(_ data: Data, id: KeyPath<Data.Element, ID>,
         @ViewBuilder content: @escaping @MainActor (Data.Element) -> Content) {
        self.data = data
        self.id = id
        self.content = content
    }

    var body: some View {
        let content = content
        let erased: @MainActor (Data.Element) -> AnyView = { AnyView(content($0)) }
        ForEach(data, id: id) { @Sendable item in BuiltOnMain(input: item, content: erased) }
    }
}

extension MainActorForEach where Data.Element: Identifiable, ID == Data.Element.ID {
    /// Rows for `data`, each identified by its own `id` and built by `content` on the main thread.
    init(_ data: Data, @ViewBuilder content: @escaping @MainActor (Data.Element) -> Content) {
        self.init(data, id: \.id, content: content)
    }
}

/// A `GeometryReader` whose content is built on the main thread (item 246), from the size the reader is given.
struct MainActorGeometryReader<Content: View>: View {
    let content: @MainActor (CGSize) -> Content

    /// Content built by `content` on the main thread, from the size the reader is given.
    init(@ViewBuilder content: @escaping @MainActor (CGSize) -> Content) {
        self.content = content
    }

    var body: some View {
        let content = content
        let erased: @MainActor (CGSize) -> AnyView = { AnyView(content($0)) }
        GeometryReader { @Sendable proxy in BuiltOnMain(input: proxy.size, content: erased) }
    }
}

/// A `TimelineView` whose pages are built on the main thread (item 246), from the date of each.
struct MainActorTimelineView<Schedule: TimelineSchedule, Content: View>: View {
    let schedule: Schedule
    let content: @MainActor (Date) -> Content

    /// Pages on `schedule`, each built by `content` on the main thread from its date.
    init(_ schedule: Schedule, @ViewBuilder content: @escaping @MainActor (Date) -> Content) {
        self.schedule = schedule
        self.content = content
    }

    var body: some View {
        let content = content
        let erased: @MainActor (Date) -> AnyView = { AnyView(content($0)) }
        TimelineView(schedule) { @Sendable context in BuiltOnMain(input: context.date, content: erased) }
    }
}
