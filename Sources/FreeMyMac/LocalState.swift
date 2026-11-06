import SwiftUI

/// Stands in for `@State`. In the macOS 27 SDK `@State` is a macro whose plugin
/// ships only with full Xcode, so it won't compile with the Command Line Tools
/// alone. This uses the same underlying `State` storage without the macro.
@propertyWrapper
struct LocalState<Value>: DynamicProperty {
    private let storage: SwiftUI.State<Value>

    init(wrappedValue: Value) {
        storage = SwiftUI.State(initialValue: wrappedValue)
    }

    var wrappedValue: Value {
        get { storage.wrappedValue }
        nonmutating set { storage.wrappedValue = newValue }
    }

    var projectedValue: Binding<Value> { storage.projectedValue }
}
