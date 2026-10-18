# Composer overlap performance benchmarks

Workload 1, 43 optimized package benchmarks. Baseline: `2026-10-17-d547087-dirty-w1.json`. The machine was quiet at measurement time (load 2.09). This run used `--no-app`; no app launch, idle CPU, memory or energy measurements were taken. Product source matches `d880587`.

The initial comparison selected an app-only baseline with no benchmark metrics. This report recomputes the comparison from the same saved measurements using the newest compatible benchmark baseline; no measurement was rerun.

| Metric | This run | Range | Baseline | Delta | Verdict |
|---|---|---|---|---|---|
| bench.decode_fixtures | 12.7 | 12.6 to 12.7 | 10.8 | +16.7% | same |
| bench.huge_cache_load | 30.3 | 30.2 to 30.4 | 24.0 | +26.1% | WORSE |
| bench.huge_cache_write | 38.7 | 38.1 to 40.3 | 30.1 | +28.6% | WORSE |
| bench.huge_full_decode | 35.3 | 35.2 to 35.8 | 31.1 | +13.7% | same |
| bench.huge_full_derive | 21.1 | 20.8 to 21.6 | 18.2 | +16.0% | same |
| bench.huge_full_entries | 17.0 | 16.8 to 17.6 | 14.3 | +18.8% | same |
| bench.huge_full_panel | 4.0 | 2.0 to 4.8 | 4.0 | +2.0% | same |
| bench.huge_full_parse | 47.5 | 47.1 to 49.4 | 41.5 | +14.6% | same |
| bench.huge_full_reduce | 0.971 | 0.962 to 1.0 | 0.826 | +17.6% | same |
| bench.huge_open_decode | 11.7 | 11.6 to 11.9 | 10.3 | +13.3% | same |
| bench.huge_open_derive | 0.174 | 0.171 to 0.190 | 0.152 | +14.3% | same |
| bench.huge_open_entries | 1.5 | 1.5 to 1.5 | 1.3 | +14.8% | same |
| bench.huge_open_long_decode | 12.5 | 12.3 to 12.8 | 10.3 | +21.9% | WORSE |
| bench.huge_open_long_derive | 0.188 | 0.188 to 0.193 | 0.144 | +30.5% | same |
| bench.huge_open_long_entries | 1.6 | 1.6 to 1.7 | 1.3 | +24.7% | WORSE |
| bench.huge_open_long_panel | 14.4 | 14.3 to 14.7 | 12.0 | +19.6% | same |
| bench.huge_open_long_parse | 21.1 | 20.4 to 21.8 | 16.7 | +26.1% | WORSE |
| bench.huge_open_long_reduce | 0.012 | 0.012 to 0.018 | 0.009 | +29.4% | same |
| bench.huge_open_panel | 6.8 | 6.6 to 7.2 | 5.6 | +21.8% | WORSE |
| bench.huge_open_parse | 19.3 | 19.1 to 20.5 | 16.6 | +16.2% | same |
| bench.huge_open_reduce | 0.012 | 0.012 to 0.015 | 0.009 | +23.7% | same |
| bench.huge_update_append | 2.5 | 2.4 to 2.6 | 1.8 | +40.1% | WORSE |
| bench.huge_update_stream | 1.1 | 1.0 to 1.3 | 0.741 | +46.4% | WORSE |
| bench.huge_update_stream_entries | 2.6 | 2.6 to 2.7 | 2.1 | +23.4% | WORSE |
| bench.huge_update_stream_rows_patch | 0.045 | 0.044 to 0.046 | 0.036 | +23.3% | same |
| bench.huge_update_tool | 0.824 | 0.789 to 0.851 | 0.549 | +50.1% | WORSE |
| bench.huge_update_tool_entries | 2.7 | 2.6 to 2.8 | 2.1 | +25.6% | WORSE |
| bench.huge_update_tool_rows_offmain | 24.2 | 23.8 to 24.5 | 19.1 | +26.8% | WORSE |
| bench.markdown_layout | 58.6 | 58.5 to 61.4 | 48.9 | +20.0% | same |
| bench.markdown_parse | 16.1 | 15.9 to 16.7 | 12.7 | +27.0% | WORSE |
| bench.markdown_parse_lines | 43.8 | 43.7 to 44.4 | 34.3 | +27.8% | WORSE |
| bench.markdown_stream_delta_full | 21.8 | 20.9 to 22.3 | 18.2 | +20.1% | WORSE |
| bench.markdown_stream_delta_incremental | 0.578 | 0.344 to 2.1 | 0.507 | +14.1% | same |
| bench.paging_huge_main | 1.8 | 1.2 to 3.0 | 1.4 | +25.9% | WORSE |
| bench.paging_huge_total | 4.5 | 2.3 to 6.9 | 3.6 | +24.1% | WORSE |
| bench.paging_seeded2000_main | 0.943 | 0.480 to 1.6 | 0.784 | +20.3% | WORSE |
| bench.paging_seeded2000_total | 1.2 | 0.480 to 3.3 | 1.0 | +21.7% | WORSE |
| bench.sidebar_items_1000 | 4.1 | 4.1 to 4.1 | 3.6 | +14.1% | same |
| bench.sidebar_rename_1580_classic | 0.505 | 0.501 to 0.527 | 0.418 | +20.9% | WORSE |
| bench.sidebar_shelf_1580_classic | 2.0 | 1.1 to 2.2 | 1.7 | +19.1% | same |
| bench.sidebar_tick_1580_classic | 0.335 | 0.313 to 0.414 | 0.273 | +22.7% | WORSE |
| bench.thread_reducer | 0.342 | 0.341 to 0.345 | 0.292 | +17.3% | same |
| bench.timeline_rows | 0.114 | 0.114 to 0.117 | 0.098 | +16.4% | same |

Regressions: bench.huge_cache_load, bench.huge_cache_write, bench.huge_open_long_decode, bench.huge_open_long_entries, bench.huge_open_long_parse, bench.huge_open_panel, bench.huge_update_append, bench.huge_update_stream, bench.huge_update_stream_entries, bench.huge_update_tool, bench.huge_update_tool_entries, bench.huge_update_tool_rows_offmain, bench.markdown_parse, bench.markdown_parse_lines, bench.markdown_stream_delta_full, bench.paging_huge_main, bench.paging_huge_total, bench.paging_seeded2000_main, bench.paging_seeded2000_total, bench.sidebar_rename_1580_classic, bench.sidebar_tick_1580_classic.
