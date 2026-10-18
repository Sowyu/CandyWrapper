# Composer overlap benchmark recheck

Warm rerun of the same optimized binary after compilation ended, using `CW_BENCH=1 scripts/test -c release -Xswiftc -enable-testing --filter PerfBenchmarks`. All 10 benchmark tests passed. This run contains 43 metrics and no app measurements. Baseline: `2026-10-17-d547087-dirty-w1.json`.

| Metric | This run | Range | Baseline | Delta | Verdict |
|---|---|---|---|---|---|
| bench.decode_fixtures | 11.3 | 11.2 to 11.3 | 10.8 | +3.7% | same |
| bench.thread_reducer | 0.300 | 0.299 to 0.302 | 0.292 | +2.8% | same |
| bench.timeline_rows | 0.102 | 0.101 to 0.103 | 0.098 | +4.0% | same |
| bench.huge_open_parse | 17.4 | 17.3 to 18.4 | 16.6 | +4.4% | same |
| bench.huge_open_decode | 10.5 | 10.5 to 10.8 | 10.3 | +1.9% | same |
| bench.huge_open_reduce | 0.011 | 0.011 to 0.019 | 0.009 | +12.7% | same |
| bench.huge_open_entries | 1.4 | 1.3 to 1.4 | 1.3 | +3.4% | same |
| bench.huge_open_derive | 0.157 | 0.154 to 0.165 | 0.152 | +3.3% | same |
| bench.huge_open_panel | 6.1 | 6.0 to 6.4 | 5.6 | +8.4% | same |
| bench.huge_full_parse | 42.0 | 41.9 to 44.0 | 41.5 | +1.4% | same |
| bench.huge_full_decode | 31.5 | 31.4 to 32.0 | 31.1 | +1.5% | same |
| bench.huge_full_reduce | 0.873 | 0.861 to 0.935 | 0.826 | +5.8% | same |
| bench.huge_full_entries | 15.5 | 15.2 to 16.0 | 14.3 | +8.3% | same |
| bench.huge_full_derive | 18.9 | 18.6 to 19.3 | 18.2 | +3.9% | same |
| bench.huge_full_panel | 5.0 | 1.9 to 6.1 | 4.0 | +26.3% | WORSE |
| bench.huge_open_long_parse | 17.7 | 17.4 to 17.7 | 16.7 | +5.7% | same |
| bench.huge_open_long_decode | 10.5 | 10.5 to 10.7 | 10.3 | +2.0% | same |
| bench.huge_open_long_reduce | 0.011 | 0.011 to 0.014 | 0.009 | +11.4% | same |
| bench.huge_open_long_entries | 1.5 | 1.4 to 1.5 | 1.3 | +12.6% | same |
| bench.huge_open_long_derive | 0.157 | 0.156 to 0.161 | 0.144 | +8.6% | same |
| bench.huge_open_long_panel | 12.5 | 12.3 to 12.7 | 12.0 | +4.2% | same |
| bench.huge_cache_write | 31.5 | 31.3 to 33.2 | 30.1 | +4.5% | same |
| bench.huge_cache_load | 25.0 | 24.9 to 25.1 | 24.0 | +4.1% | same |
| bench.huge_update_stream | 0.875 | 0.812 to 0.991 | 0.741 | +18.2% | same |
| bench.huge_update_tool | 0.647 | 0.620 to 0.651 | 0.549 | +17.8% | same |
| bench.huge_update_append | 1.9 | 1.9 to 1.9 | 1.8 | +8.0% | same |
| bench.huge_update_stream_entries | 2.2 | 2.2 to 2.3 | 2.1 | +4.1% | same |
| bench.huge_update_stream_rows_patch | 0.034 | 0.034 to 0.037 | 0.036 | -5.1% | same |
| bench.huge_update_tool_entries | 2.2 | 2.2 to 2.3 | 2.1 | +3.2% | same |
| bench.huge_update_tool_rows_offmain | 19.6 | 19.3 to 19.6 | 19.1 | +2.4% | same |
| bench.markdown_parse | 13.1 | 12.9 to 13.2 | 12.7 | +3.3% | same |
| bench.markdown_parse_lines | 35.6 | 35.4 to 36.2 | 34.3 | +3.7% | same |
| bench.markdown_layout | 51.0 | 50.7 to 51.2 | 48.9 | +4.3% | same |
| bench.markdown_stream_delta_full | 18.9 | 18.6 to 19.2 | 18.2 | +4.1% | same |
| bench.markdown_stream_delta_incremental | 0.516 | 0.305 to 1.9 | 0.507 | +1.8% | same |
| bench.sidebar_items_1000 | 3.7 | 3.6 to 3.7 | 3.6 | +1.8% | same |
| bench.sidebar_rename_1580_classic | 0.432 | 0.416 to 0.448 | 0.418 | +3.3% | same |
| bench.sidebar_tick_1580_classic | 0.295 | 0.275 to 0.360 | 0.273 | +8.2% | same |
| bench.sidebar_shelf_1580_classic | 1.7 | 0.926 to 1.8 | 1.7 | +2.1% | same |
| bench.paging_seeded2000_main | 0.836 | 0.420 to 1.4 | 0.784 | +6.6% | same |
| bench.paging_seeded2000_total | 1.1 | 0.420 to 3.0 | 1.0 | +8.1% | same |
| bench.paging_huge_main | 1.7 | 1.0 to 2.7 | 1.4 | +16.2% | same |
| bench.paging_huge_total | 3.8 | 2.1 to 6.1 | 3.6 | +6.3% | same |

Regressions: bench.huge_full_panel.
