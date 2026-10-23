#if os(macOS)
import SwiftUI

// In newer macOS SDKs `@State` and `@FocusState` are macros whose plugin ships only with full Xcode,
// so they fail to build with just the Command Line Tools. These wrappers hold the same SwiftUI
// storage as plain stored properties (no macro), which SwiftUI still discovers through DynamicProperty.

/// Drop-in replacement for `@State`.
@propertyWrapper
struct ViewState<Value>: DynamicProperty {
    private var storage: State<Value>

    init(wrappedValue: Value) { storage = State(initialValue: wrappedValue) }

    var wrappedValue: Value {
        get { storage.wrappedValue }
        nonmutating set { storage.wrappedValue = newValue }
    }
    var projectedValue: Binding<Value> { storage.projectedValue }
}

/// Drop-in replacement for `@FocusState` with a Bool value.
@propertyWrapper
struct ViewFocus: DynamicProperty {
    private var storage = FocusState<Bool>()

    var wrappedValue: Bool {
        get { storage.wrappedValue }
        nonmutating set { storage.wrappedValue = newValue }
    }
    var projectedValue: FocusState<Bool>.Binding { storage.projectedValue }
}
#endif
