import SwiftUI

extension Binding {
    /// A two-way `Bool` binding driven by whether an optional has a value.
    ///
    /// `isPresented: .constant(x != nil)` looks equivalent but is not: a
    /// constant binding silently discards writes, so when SwiftUI tries to
    /// dismiss the alert the condition is still true and it presents it again
    /// immediately. That loop is what filled the log with "Attempting to
    /// present a confirmation dialog while an alert is already presented", and
    /// a presentation stuck in that state swallows touches — taps on the view
    /// underneath need several attempts before one lands.
    ///
    /// Setting this to `false` clears the underlying optional, so a dismissal
    /// actually sticks.
    static func presenting<T>(_ value: Binding<T?>) -> Binding<Bool> where Value == Bool {
        Binding<Bool>(
            get: { value.wrappedValue != nil },
            set: { if !$0 { value.wrappedValue = nil } }
        )
    }
}
