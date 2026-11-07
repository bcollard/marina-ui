import Foundation

enum SidebarSelection: Hashable, Sendable {
    case cluster(name: String)
    case mirror(name: String)
    /// A container in the guest VM that marina doesn't manage, keyed by its
    /// full docker ID — names are mutable and not guaranteed unique over time.
    case container(id: String)
    /// A fleet (the marina.run/fleet node label value).
    case fleet(name: String)
}
