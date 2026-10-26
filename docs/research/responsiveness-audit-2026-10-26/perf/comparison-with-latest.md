# Comparison with the latest saved run

Same measured values as `2026-10-26-0ced803-w1.json`, compared with `2026-10-25-14567ec-w1.json`. No second measurement was made.

| Metric | This run | Range | Baseline | Delta | Verdict |
|---|---|---|---|---|---|
| bench.decode_fixtures | 11.4 | 11.4 to 11.6 | 11.3 | +0.9% | same |
| bench.huge_cache_load | 27.6 | 27.6 to 29.0 | 25.7 | +7.7% | same |
| bench.huge_cache_write | 35.4 | 34.9 to 37.6 | 32.4 | +9.0% | same |
| bench.huge_full_decode | 36.1 | 35.8 to 36.4 | 35.6 | +1.4% | same |
| bench.huge_full_derive | 20.2 | 20.1 to 20.6 | 20.4 | -0.8% | same |
| bench.huge_full_entries | 16.3 | 16.2 to 16.8 | 15.4 | +6.0% | same |
| bench.huge_full_panel | 4.4 | 2.1 to 5.5 | 4.4 | +0.9% | same |
| bench.huge_full_parse | 42.4 | 42.3 to 44.4 | 42.3 | +0.3% | same |
| bench.huge_full_reduce | 0.867 | 0.865 to 0.880 | 0.876 | -1.0% | same |
| bench.huge_open_decode | 11.0 | 11.0 to 11.2 | 11.2 | -1.8% | same |
| bench.huge_open_derive | 0.171 | 0.169 to 0.180 | 0.176 | -2.9% | same |
| bench.huge_open_entries | 1.4 | 1.4 to 1.4 | 1.4 | -2.2% | same |
| bench.huge_open_long_decode | 11.7 | 11.7 to 11.8 | 11.2 | +4.3% | same |
| bench.huge_open_long_derive | 0.189 | 0.186 to 0.193 | 0.169 | +11.6% | same |
| bench.huge_open_long_entries | 1.5 | 1.5 to 1.5 | 1.4 | +9.7% | same |
| bench.huge_open_long_panel | 13.5 | 13.3 to 14.5 | 12.0 | +12.2% | same |
| bench.huge_open_long_parse | 18.9 | 18.7 to 19.3 | 17.6 | +7.1% | same |
| bench.huge_open_long_reduce | 0.012 | 0.012 to 0.018 | 0.010 | +14.4% | same |
| bench.huge_open_panel | 6.3 | 6.1 to 6.7 | 6.3 | +0.5% | same |
| bench.huge_open_parse | 17.5 | 17.4 to 18.4 | 17.2 | +1.4% | same |
| bench.huge_open_reduce | 0.011 | 0.010 to 0.012 | 0.011 | -3.4% | same |
| bench.huge_update_append | 4.1 | 3.8 to 4.2 | 3.3 | +27.0% | WORSE |
| bench.huge_update_stream | 2.3 | 2.3 to 2.6 | 2.0 | +19.0% | same |
| bench.huge_update_stream_entries | 3.1 | 3.1 to 3.5 | 2.8 | +11.9% | same |
| bench.huge_update_stream_rows_patch | 0.055 | 0.052 to 0.058 | 0.044 | +25.0% | same |
| bench.huge_update_tool | 2.0 | 2.0 to 2.1 | 1.8 | +16.3% | same |
| bench.huge_update_tool_entries | 3.3 | 3.1 to 3.5 | 2.8 | +18.0% | same |
| bench.huge_update_tool_rows_offmain | 29.9 | 29.8 to 33.4 | 27.9 | +7.0% | same |
| bench.markdown_layout | 61.5 | 58.7 to 61.7 | 66.9 | -8.0% | same |
| bench.markdown_parse | 18.8 | 18.5 to 19.0 | 18.7 | +0.4% | same |
| bench.markdown_parse_lines | 47.0 | 46.8 to 51.1 | 52.4 | -10.3% | same |
| bench.markdown_stream_delta_full | 23.0 | 22.4 to 23.6 | 23.6 | -2.7% | same |
| bench.markdown_stream_delta_incremental | 0.665 | 0.398 to 2.4 | 0.665 | -0.1% | same |
| bench.paging_huge_main | 2.2 | 1.4 to 3.7 | 2.2 | +1.5% | same |
| bench.paging_huge_total | 5.2 | 2.8 to 8.8 | 5.2 | -0.6% | same |
| bench.paging_seeded2000_main | 1.2 | 0.623 to 1.9 | 1.2 | +1.9% | same |
| bench.paging_seeded2000_total | 1.5 | 0.623 to 4.1 | 1.5 | +0.7% | same |
| bench.sidebar_items_1000 | 5.0 | 5.0 to 5.1 | 4.9 | +2.6% | same |
| bench.sidebar_rename_1580_classic | 0.734 | 0.701 to 0.747 | 0.659 | +11.4% | same |
| bench.sidebar_shelf_1580_classic | 2.5 | 1.4 to 2.7 | 2.3 | +10.6% | same |
| bench.sidebar_tick_1580_classic | 0.533 | 0.478 to 0.636 | 0.410 | +30.0% | WORSE |
| bench.thread_reducer | 0.308 | 0.306 to 0.310 | 0.303 | +1.7% | same |
| bench.timeline_rows | 0.109 | 0.108 to 0.110 | 0.108 | +0.8% | same |

Flags: bench.huge_update_append, bench.sidebar_tick_1580_classic
