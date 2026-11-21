import Testing

/// Suites whose tests set the global theme while another's work reads it off the main thread run one at a time:
/// `ModelPickerShrinkTests` applies Redesign and Glass while `MarkdownBackgroundLayoutTests` lays out in the
/// background, and the background layout read the picker's theme (1.16.0 release walk).
@Suite(.serialized) @MainActor enum GlobalThemeSuites {}

/// The old names, for the suites that borrow their fixtures.
typealias ModelPickerShrinkTests = GlobalThemeSuites.ModelPickerShrinkTests
typealias MarkdownBackgroundLayoutTests = GlobalThemeSuites.MarkdownBackgroundLayoutTests
