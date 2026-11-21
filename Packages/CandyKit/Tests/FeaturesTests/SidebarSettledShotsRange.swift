import AppKit
@testable import DesignSystem
import T3Store
@testable import Features

extension SidebarSettledShots {
    /// The "when" picker open, a range applied, and a range with nothing in it.
    static func extraShots(_ out: URL, dark: Bool) throws {
        try shot("settled-when-open", out, dark: dark, settled: true, height: 1400) { sidebar in
            if let header = sidebar.list.view(forKey: "shelf:settled") as? SidebarShelfRowView {
                sidebar.toggleSettledRangePicker(header.rangeButton)
            }
        }
        try shot("settled-yesterday", out, dark: dark, settled: true) { $0.setSettledRange(.yesterday); $0.layoutSubtreeIfNeeded() }
        try shot("settled-empty", out, dark: dark, settled: true, olderOnly: true) { $0.setSettledRange(.yesterday); $0.layoutSubtreeIfNeeded() }
    }
}
