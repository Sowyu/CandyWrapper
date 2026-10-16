# Perf review 0a2416f-dirty

Run 2026-10-16T02:31:51 on Mac16,10, workload 1, microbenchmarks only (`--no-app`), after the sidebar scan fix. Baseline: 2026-10-15-a3077d8-w1.json.

Quiet waits (s, 1-minute load when measuring started): bench 0 s, load 2.05

| Metric | This run | Range | Baseline | Delta | Verdict |
|---|---|---|---|---|---|
| bench.decode_fixtures | 9.8 | 9.7 to 9.9 | 9.6 | +1.3% | same |
| bench.thread_reducer | 0.284 | 0.282 to 0.286 | 0.292 | -2.9% | same |
| bench.timeline_rows | 0.098 | 0.097 to 0.100 | 0.098 | +0.4% | same |
| bench.huge_open_parse | 16.9 | 16.8 to 17.3 | 16.8 | +0.1% | same |
| bench.huge_open_decode | 10.1 | 10.1 to 10.3 | 10.7 | -5.2% | same |
| bench.huge_open_reduce | 0.009 | 0.009 to 0.017 | 0.010 | -1.8% | same |
| bench.huge_open_entries | 1.3 | 1.3 to 1.4 | 1.3 | -1.8% | same |
| bench.huge_open_derive | 0.159 | 0.150 to 0.162 | 0.165 | -3.5% | same |
| bench.huge_open_panel | 5.9 | 5.8 to 6.3 | 5.9 | +0.8% | same |
| bench.huge_full_parse | 61.1 | 60.9 to 62.9 | 41.0 | +48.9% | WORSE |
| bench.huge_full_decode | 31.4 | 31.3 to 31.7 | 31.6 | -0.9% | same |
| bench.huge_full_reduce | 0.836 | 0.825 to 0.861 | 0.884 | -5.4% | same |
| bench.huge_full_entries | 14.7 | 14.5 to 15.7 | 14.4 | +1.9% | same |
| bench.huge_full_derive | 20.9 | 20.4 to 21.1 | 19.0 | +9.8% | same |
| bench.huge_full_panel | 4.2 | 1.8 to 4.7 | 4.1 | +1.6% | same |
| bench.huge_open_long_parse | 17.0 | 16.9 to 17.0 | 17.1 | -1.1% | same |
| bench.huge_open_long_decode | 10.1 | 10.0 to 10.2 | 10.5 | -4.2% | same |
| bench.huge_open_long_reduce | 0.010 | 0.010 to 0.014 | 0.010 | +7.3% | same |
| bench.huge_open_long_entries | 1.3 | 1.3 to 1.3 | 1.3 | -0.6% | same |
| bench.huge_open_long_derive | 0.150 | 0.144 to 0.154 | 0.159 | -5.6% | same |
| bench.huge_open_long_panel | 11.9 | 11.8 to 12.2 | 12.1 | -1.6% | same |
| bench.huge_cache_write | 30.1 | 29.8 to 32.8 | 30.6 | -1.5% | same |
| bench.huge_cache_load | 24.5 | 24.3 to 24.6 | 24.1 | +1.8% | same |
| bench.huge_update_stream | 0.716 | 0.676 to 0.867 | 0.730 | -1.9% | same |
| bench.huge_update_tool | 0.556 | 0.532 to 0.576 | 0.542 | +2.6% | same |
| bench.huge_update_append | 1.8 | 1.7 to 1.9 | 1.8 | +0.6% | same |
| bench.huge_update_stream_entries | 2.1 | 2.1 to 2.2 | 2.1 | +1.3% | same |
| bench.huge_update_stream_rows_patch | 0.035 | 0.033 to 0.037 | 0.034 | +5.3% | same |
| bench.huge_update_tool_entries | 2.1 | 2.1 to 2.2 | 2.1 | +1.6% | same |
| bench.huge_update_tool_rows_offmain | 19.3 | 19.2 to 19.4 | 18.7 | +3.0% | same |
| bench.markdown_parse | 12.8 | 12.6 to 13.2 | 12.9 | -0.6% | same |
| bench.markdown_parse_lines | 35.4 | 34.9 to 35.8 | 35.2 | +0.5% | same |
| bench.markdown_layout | 48.7 | 48.5 to 49.8 | 49.2 | -1.1% | same |
| bench.markdown_stream_delta_full | 18.5 | 18.0 to 19.1 | 18.3 | +1.0% | same |
| bench.markdown_stream_delta_incremental | 0.476 | 0.291 to 1.8 | 0.497 | -4.2% | same |
| bench.sidebar_items_1000 | 3.5 | 3.5 to 3.5 | 3.5 | -1.1% | same |
| bench.sidebar_rename_1580_classic | 0.389 | 0.383 to 0.500 | 0.425 | -8.4% | same |
| bench.sidebar_tick_1580_classic | 0.281 | 0.251 to 0.325 | 0.296 | -4.8% | same |
| bench.sidebar_shelf_1580_classic | 1.7 | 0.893 to 1.8 | 1.8 | -8.8% | same |
| bench.paging_seeded2000_main | 0.791 | 0.403 to 1.4 | 0.786 | +0.7% | same |
| bench.paging_seeded2000_total | 1.1 | 0.403 to 2.7 | 1.0 | +4.2% | same |
| bench.paging_huge_main | 1.4 | 0.894 to 2.6 | 1.4 | +0.4% | same |
| bench.paging_huge_total | 3.6 | 1.9 to 5.8 | 3.7 | -2.8% | same |

Regressions: bench.huge_full_parse
