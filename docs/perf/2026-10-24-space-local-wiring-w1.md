# Space local wiring performance review

NOISY: other builds and test apps were active. App scenarios used one launch per case and a ten-second idle window. Both initial 600-second quiet waits expired; remaining waits were capped at zero. Metrics and thresholds stayed unchanged.

Baseline: `2026-10-24-6f6f14b-w1.json`, the last saved run before this review. It contains no app values. The app rows are new measurements, not a regression verdict.

| Metric | This run | Range | Baseline | Delta | Verdict |
|---|---|---|---|---|---|
| big_thread.after_scroll_footprint_mb | 51.8 |  | - | - | new |
| big_thread.after_scroll_peak_mb | 106.6 |  | - | - | new |
| big_thread.dropped_frames | 35.0 |  | - | - | new |
| big_thread.footprint_mb | 43.4 |  | - | - | new |
| big_thread.peak_footprint_mb | 89.9 |  | - | - | new |
| big_thread.scroll_cpu_ms | 808.5 |  | - | - | new |
| big_thread.stall_count_50ms | 5.0 |  | - | - | new |
| big_thread.stall_max_ms | 207.1 |  | - | - | new |
| idle.cpu_pct | 0.098 |  | - | - | new |
| idle.footprint_mb | 42.0 |  | - | - | new |
| idle.interrupt_wakeups_per_s | 0.997 |  | - | - | new |
| idle.package_idle_wakeups_per_s | 0.000 |  | - | - | new |
| idle.peak_footprint_mb | 88.2 |  | - | - | new |
| launch.cached_sidebar_ms | 2795.0 |  | - | - | new |
| launch.live_sidebar_ms | 3029.0 |  | - | - | new |
| launch.stall_count_50ms | 0.000 |  | - | - | new |
| launch.stall_max_ms | 0.000 |  | - | - | new |
| launch.window_ms | 2666.0 |  | - | - | new |
| open.big_cache_first_frame_ms | 179.1 |  | - | - | new |
| open.big_first_frame_ms | 178.9 |  | - | - | new |
| open.big_reopen_first_frame_ms | 100.5 |  | - | - | new |
| open.stall_count_50ms | 5.0 |  | - | - | new |
| open.stall_max_ms | 108.0 |  | - | - | new |
| size.binary_mb | 51.7 |  | - | - | new |
| size.bundle_mb | 61.4 |  | - | - | new |
| size.shipped_bundle_mb | 35.4 |  | - | - | new |
| size.stripped_binary_mb | 26.8 |  | - | - | new |
| bench.decode_fixtures | 60.5 | 54.1 to 66.5 | 11.1 | +443.4% | WORSE |
| bench.huge_cache_load | 128.1 | 119.0 to 130.9 | 38.3 | +234.5% | WORSE |
| bench.huge_cache_write | 151.5 | 149.0 to 160.5 | 53.4 | +183.7% | WORSE |
| bench.huge_full_decode | 148.4 | 146.8 to 150.7 | 38.2 | +288.8% | WORSE |
| bench.huge_full_derive | 94.3 | 93.4 to 94.4 | 27.4 | +244.7% | WORSE |
| bench.huge_full_entries | 69.8 | 69.4 to 74.6 | 19.1 | +265.3% | WORSE |
| bench.huge_full_panel | 13.7 | 10.4 to 13.9 | 4.6 | +201.4% | WORSE |
| bench.huge_full_parse | 204.4 | 197.0 to 210.9 | 45.4 | +349.9% | WORSE |
| bench.huge_full_reduce | 3.9 | 3.9 to 4.1 | 1.1 | +254.7% | WORSE |
| bench.huge_open_decode | 50.0 | 49.4 to 51.3 | 10.4 | +379.7% | WORSE |
| bench.huge_open_derive | 0.909 | 0.903 to 0.926 | 0.174 | +421.4% | WORSE |
| bench.huge_open_entries | 6.4 | 6.3 to 6.8 | 1.3 | +371.8% | WORSE |
| bench.huge_open_long_decode | 51.1 | 50.6 to 56.5 | 16.1 | +216.8% | WORSE |
| bench.huge_open_long_derive | 0.816 | 0.803 to 0.841 | 0.255 | +220.3% | WORSE |
| bench.huge_open_long_entries | 6.4 | 6.4 to 6.5 | 2.0 | +211.3% | WORSE |
| bench.huge_open_long_panel | 60.1 | 58.9 to 62.7 | 19.3 | +211.2% | WORSE |
| bench.huge_open_long_parse | 91.8 | 84.6 to 92.4 | 27.0 | +239.8% | WORSE |
| bench.huge_open_long_reduce | 0.054 | 0.049 to 0.070 | 0.015 | +252.0% | same |
| bench.huge_open_panel | 45.3 | 41.3 to 47.6 | 6.5 | +592.8% | WORSE |
| bench.huge_open_parse | 82.4 | 81.7 to 86.6 | 17.3 | +376.2% | WORSE |
| bench.huge_open_reduce | 0.048 | 0.047 to 0.055 | 0.011 | +352.2% | same |
| bench.huge_update_append | 13.1 | 12.7 to 13.4 | 3.6 | +262.2% | WORSE |
| bench.huge_update_stream | 9.9 | 9.6 to 10.5 | 2.7 | +269.7% | WORSE |
| bench.huge_update_stream_entries | 10.2 | 10.0 to 10.4 | 2.9 | +257.5% | WORSE |
| bench.huge_update_stream_rows_patch | 0.179 | 0.171 to 0.183 | 0.044 | +303.8% | WORSE |
| bench.huge_update_tool | 8.2 | 7.4 to 8.3 | 2.3 | +263.2% | WORSE |
| bench.huge_update_tool_entries | 10.5 | 9.9 to 10.9 | 2.9 | +264.9% | WORSE |
| bench.huge_update_tool_rows_offmain | 112.5 | 106.8 to 112.7 | 27.7 | +306.8% | WORSE |
| bench.markdown_layout | 252.5 | 241.9 to 321.2 | 64.3 | +292.5% | WORSE |
| bench.markdown_parse | 65.1 | 61.9 to 70.8 | 16.1 | +305.3% | WORSE |
| bench.markdown_parse_lines | 174.2 | 170.7 to 190.1 | 45.4 | +283.2% | WORSE |
| bench.markdown_stream_delta_full | 90.2 | 88.8 to 94.5 | 24.6 | +267.4% | WORSE |
| bench.markdown_stream_delta_incremental | 2.4 | 1.4 to 8.9 | 0.690 | +255.0% | WORSE |
| bench.paging_huge_main | 7.6 | 5.1 to 13.2 | 2.3 | +234.7% | WORSE |
| bench.paging_huge_total | 18.9 | 10.2 to 31.5 | 5.2 | +259.4% | WORSE |
| bench.paging_seeded2000_main | 4.5 | 2.2 to 6.8 | 1.3 | +258.2% | WORSE |
| bench.paging_seeded2000_total | 5.4 | 2.2 to 12.9 | 1.5 | +254.9% | WORSE |
| bench.sidebar_items_1000 | 18.0 | 17.9 to 18.4 | 5.2 | +249.5% | WORSE |
| bench.sidebar_rename_1580_classic | 2.3 | 2.3 to 2.5 | 0.653 | +258.8% | WORSE |
| bench.sidebar_shelf_1580_classic | 8.3 | 4.5 to 8.6 | 2.3 | +258.0% | WORSE |
| bench.sidebar_tick_1580_classic | 1.6 | 1.5 to 1.9 | 0.442 | +258.4% | WORSE |
| bench.thread_reducer | 1.5 | 1.5 to 1.6 | 0.301 | +400.9% | WORSE |
| bench.timeline_rows | 0.515 | 0.507 to 0.528 | 0.109 | +373.0% | WORSE |

Note: the machine was not quiet before every scenario within 10 minutes; see quiet.waits

Note: the machine was not quiet before every scenario within 10 minutes; see quiet.waits

Note: The original app and benchmark quiet waits each expired after 600 seconds. Remaining quiet waits were capped at zero; all samples remain marked noisy. Metric code and thresholds were unchanged.

Note: The benchmark launcher began a redundant rebuild. The final measurements used the already completed Release FeaturesTests bundle through scripts/test with --skip-build. A process-path probe confirmed Products/Release/FeaturesTests.xctest/Contents/MacOS/FeaturesTests.

Note: App scenarios and micro-benchmarks were collected separately and combined here. The latest saved baseline contains only micro-benchmarks, so the app values have no comparison verdict.

Note: Forty-one of 43 micro-benchmarks exceed the baseline thresholds. The run cannot establish attribution; repeat a quiet same-code control before deciding whether these are regressions.
