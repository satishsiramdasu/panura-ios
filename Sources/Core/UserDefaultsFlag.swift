import Foundation

extension UserDefaults {
    /// A stored switch whose default is not necessarily `false`.
    ///
    /// `bool(forKey:)` reads an unset key as `false`, which is the wrong answer
    /// for every preference that ships switched on: the first launch would have
    /// it off, and it would come on only once somebody toggled it twice. The
    /// views get this right for free — `@AppStorage` takes the default in its
    /// declaration — but the model objects that read the same keys do not have
    /// a property wrapper to lean on.
    func flag(_ key: String, default value: Bool) -> Bool {
        object(forKey: key) as? Bool ?? value
    }
}
