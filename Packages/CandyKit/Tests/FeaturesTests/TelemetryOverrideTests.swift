import Testing
import T3Protocol
@testable import Features

/// Where a running OTLP endpoint came from (TelemetryExportSettings.tsx:43-53, e78297d891).
@MainActor
struct TelemetryOverrideTests {
    @Test func environmentAndDesktopSourcesOverride() {
        let o: JSONValue = .object([
            "otlpTracesUrl": .string("http://collector:4318/v1/traces"), "otlpTracesSource": .string("environment"),
            "otlpTracesVariable": .string("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"),
            "otlpLogsUrl": .string("http://desk:4318/v1/logs"), "otlpLogsSource": .string("bootstrap"),
            "otlpMetricsUrl": .string("http://saved:4318/v1/metrics"), "otlpMetricsSource": .string("settings"),
        ])
        #expect(TelemetryExportView.runningOverride(o, key: "otlpTracesUrl")
            == .init(url: "http://collector:4318/v1/traces", label: "Set by environment", variable: "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"))
        #expect(TelemetryExportView.runningOverride(o, key: "otlpLogsUrl") == .init(url: "http://desk:4318/v1/logs", label: "Set by desktop", variable: nil))
        #expect(TelemetryExportView.runningOverride(o, key: "otlpMetricsUrl") == nil)
        #expect(TelemetryExportView.runningOverride(nil, key: "otlpTracesUrl") == nil)
    }
}
