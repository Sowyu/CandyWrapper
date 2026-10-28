# Nightly 3814 commit coverage

Every commit from `git log v0.1.3-nightly.20261025.3669..v0.1.4-nightly.20261028.3814 -- apps/web/src packages/client-runtime packages/contracts packages/shared`, in order, with the research verdict and its status in CandyWrapper. The research notes with T3 and CW file:line for each are in ~/CandyWrapper-research/notes/nightly-3814/findings-*.md. "Open" means it applies and isn't ported yet; "n/a" means web-only, mobile-only, a refactor or a test.

| Commit | Subject | Area | Applies | Status |
|---|---|---|---|---|
| bbdc13640c | feat(desktop): import cookies from Zen Browser (#22970) | other | yes | open |
| 87d22b00f7 | perf(shared): avoid repeated date parsing when selecting PRs (#22891) | pr/git | no | n/a |
| 5b35402623 | fix(web): refresh the current branch when opening the picker (#22807) | pr/git | yes | ported (c0172900) |
| efea68679f | feat(web): attach svg files to messages (#21355) | composer | yes | open |
| 532023a241 | feat(server): send pdf attachments to claude and antigravity as documents (#21358) | wire | server-only | free with runtime |
| 34e9c56b9b | feat(web): play audio inline and open any file the agent shares in the viewer (#21363) | thread | yes | open |
| 5d9a5c9803 | perf(pull-requests): faster pull request timeline, code tab, summary and search (#22697) | pr/git | yes | open |
| d414cb5103 | fix(web): question options show a radio and an aligned shortcut key (#23255) | composer | yes | open |
| 557db6cb4e | fix(server): running delegates tell agents to end the turn (#24887) | other | server-only | free with runtime |
| b3b2c55369 | perf(source-control): pull request previews read only the pull request (#22583) | pr/git | yes | open |
| 3816296021 | feat(web): UI design overhaul, with the new look behind a Beta toggle (#24865) | other | yes (design) | phase 2 (design) |
| abd9d9f970 | perf: opening a thread loads 85% less data (#24899) | wire | yes | ported (3471d72d) |
| a960f5602f | fix(observability): every app reports its own environment and release channel (#24340) | other | no | n/a |
| 01fe8d9188 | fix(observability): every exported resource names its service instance (#23973) | other | no | n/a |
| 5f1f604733 | feat(mobile): on-demand chrome e2e runner across simulators | other | no | n/a |
| 2ed92618e6 | fix: restore files reverted by 5f1f604 | other | no | n/a |
| 2fd28bf938 | fix(client-runtime): "Codex (hub)" badges read CH instead of C( (#22918) | composer | yes | ported (4d56c379) |
| a27b246162 | fix(web): usage-limit banner reset time follows the Time format setting (#22915) | composer | yes | ported (e28c8b5f) |
| 313ca2715f | fix(web): terminal drag selection scrolls faster the farther past the edge (#22872) | other | yes | open |
| 20ee805de9 | fix(observability): resources add OTel semconv runtime and browser keys (#23972) | other | no | n/a |
| b2baf75337 | fix(web): asset URLs re-mint per revision and before expiry without effects (#24970) | thread | yes | open |
| 7561c2e631 | fix(web): queued-message edits survive navigation and settle once (#24972) | composer | yes | open |
| d99776351c | refactor(mobile): thread visits are tracked outside React (#24973) | thread | no | n/a |
| 6016969887 | refactor(client): cloud account transitions run in one service (#24974) | connections | no | n/a |
| 604ecb6d9a | refactor(client): one VCS status refresh owner per checkout (#24975) | pr/git | no | n/a |
| 4ee47883ef | refactor(web): document appearance and title are applied from app start (#25004) | other | no | n/a |
| b457b64a76 | refactor(web): app shell shortcuts register once through one command dispatcher (#25016) | other | no | n/a |
| c6b9c389ff | refactor(web): shared intersection and document-activity stores (#25020) | other | no | n/a |
| 1c10563ddb | refactor(web): the theme store and diff worker pool stop syncing the theme through effects (#25007) | other | no | n/a |
| b76a110aa4 | perf(mobile): compact persisted thread snapshots (#24265) | thread | no | n/a |
| b6c326d12f | fix(server): background compactions no longer flip threads to Working (#25122) | wire | server-only | free with runtime |
| dd2842f238 | fix(web): a stale queued-edit save no longer clears a newer edit (#25128) | composer | yes | open |
| 264969317c | fix(client): a thread opened before its shell loads still counts as opened (#25133) | thread | yes | open |
| c298a401f2 | perf(web): diff file boundaries observe visibility once instead of on every render (#25134) | pr/git | no | n/a |
| 1a13127c15 | test(web): Arabic arrow-key test no longer drops its first key press (#25145) | other | no | n/a |
| 0aeb620a1c | chore(lint): enforce mapSomeToAsSome (#25078) | other | no | n/a |
| 10d800cfed | chore(lint): enforce unicorn/require-module-specifiers (#25102) | other | no | n/a |
| 15c6e6b4ba | chore(lint): enforce unicorn/no-useless-fallback-in-spread (#25103) | other | no | n/a |
| b0f5d44475 | chore(lint): enforce eslint/no-unneeded-ternary (#25105) | other | no | n/a |
| f9956434fa | fix(web): preview favicons resolve their project without ChatView syncing it (#25068) | other | yes | open |
| 65822d8e17 | refactor(web): composer editor stops mirroring props into refs with effects (#25079) | composer | no | n/a |
| 03df289735 | fix(client): usage-limit Snooze disables at reset even weeks away, via a shared deadline clock (#25005) | composer | yes | ported (e28c8b5f) |
| 0ad399c6c5 | test(web): the diff boundary observer counter lives in its fixture (#25170) | other | no | n/a |
| 07066c0406 | fix(client): a queued-edit save keeps its claim until it finishes (#25169) | composer | yes | open |
| 5fee09a2c1 | refactor(web): terminal focus requests name the terminal they focus (#25009) | other | no | n/a |
| f4e140764f | fix(web): pull request checks stay current after a checks refresh (#25008) | pr/git | yes | open |
| e14d08c664 | fix(web): settings panels derive state instead of syncing it with effects (#25070) | settings | yes | open |
| 5786e12981 | refactor(mobile): terminal lifecycle runs in a session store, not screen effects (#25071) | other | no | n/a |
| 9f7b8ade1b | refactor(web): branch toolbar and dialogs stop syncing through effects (#25072) | palette | yes | open |
| f16ae12bb6 | refactor(web): thread find state lives in one store instead of event buses and mirrors (#25073) | thread | no | n/a |
| 9296c20e82 | refactor(web): browser panel tabs follow preview sessions without ChatView effects (#25006) | other | yes | open |
| 11bd26e4b5 | chore(lint): enforce effectSucceedWithVoid (#25074) | other | no | n/a |
| 9c02109b19 | chore(lint): enforce preferSucceedSomeOrNone (#25080) | other | no | n/a |
| 312a12d726 | chore(lint): enforce unnecessaryFailYieldableError (#25083) | other | no | n/a |
| 9ae08d550e | chore(lint): enforce catchToOrElseSucceed (#25084) | other | no | n/a |
| a8b692b3b8 | chore(lint): enforce preferTypedSchemaDecoder (#25094) | other | no | n/a |
| a0b246d0de | chore(lint): enforce tryCatchInEffectGen (#25097) | other | no | n/a |
| a320762cbc | chore(lint): enforce eslint/no-unused-vars (#25100) | other | no | n/a |
| 4e43779f82 | fix(web): theme editor returns to its spot after the window shrinks and grows back (#25076) | settings | yes | open |
| 7a95549b94 | refactor(client): drop the VCS wake and dispatcher element scope options nobody uses (#25152) | other | no | n/a |
| 122c5f8ffc | fix(web): keep Windows thread notifications clickable until handled (#22520) | other | no | n/a |
| 3ca62a5644 | refactor(client): terminal sessions keep one driver per mode (#25186) | other | no | n/a |
| b16728af84 | refactor(web): preview tab sync subscribes to the preview store instead of its own listener sets (#25196) | other | no | n/a |
| 3de45c6254 | feat(sidebar): working section is on by default (#25190) | sidebar | yes | open |
| d69810a97a | feat(web): preview office files, fonts, and mermaid diagrams (#21362) | other | yes | open |
| 73afb57097 | feat(web): virtualize large file previews (#21466) | other | yes | open |
| 9d17a02782 | feat(web): preview archives, sqlite databases, and decoded images (#21467) | other | yes | open |
| 34ead566d4 | feat(web): preview opendocument, epub, rich text, and notebooks (#21469) | other | yes | open |
| fd71ddc223 | fix(desktop): hidden preview tabs throttle instead of running at full speed (#25184) | other | no | n/a |
| f44fea47a0 | chore(lint): enforce react/no-array-index-key (#25112) | other | no | n/a |
| f10a04b7fa | chore(lint): disable unicorn/prefer-add-event-listener (#25047) | other | no | n/a |
| 1cd44f0d55 | chore(lint): disable eslint/no-control-regex (#25049) | other | no | n/a |
| f88b33a16d | fix(web): thread find exports the timeline fields type its context names (#25260) | thread | no | n/a |
| f279070244 | fix(web): Escape and copy work in chat media and markdown widgets, which attach through ref callbacks (#25246) | thread | yes | open |
| f512ff6159 | fix(web): composer banners, menus and pickers act in their handlers (#25238) | composer | yes | open |
| 0a3b561bc0 | refactor(web): device panel reads hub state from atoms (#25265) | other | no | n/a |
| c3888da8b4 | feat(web): New design brings back color where it means something (#25251) | other | yes (design) | phase 2 (design) |
| 02f4ba75a2 | fix(web): SSH password prompts wait for their dialog, and the app shell drops its sync effects (#25239) | connections | yes | ported (20b83f21) |
| a2589f22d3 | fix(mobile): review opens on Changes and keeps the section you picked (#25223) | pr/git | no | n/a |
| 1de64942be | chore(lint): enforce react/purity (#25038) | sidebar | yes | open |
| 8a4ad9452a | refactor(web): root notification and toast coordinators start with the app (#25233) | other | no | n/a |
| 6a3a460b09 | refactor(web): sidebar thread lists derive state instead of syncing it in effects (#25234) | sidebar | no | n/a |
| 9d6a2e57fc | fix(web): new thread shortcut focuses palette search, not the Back button (#25315) | palette | yes | already so |
| 72d4dc9b1e | fix(web): composer corners and context strip no longer show double edges (#25316) | composer | yes (design) | phase 2 (design) |
| f1b8758316 | fix(web): VS Code icon in thread details no longer has a box around it (#25321) | thread | yes (design) | phase 2 (design) |
| 7df7cb9999 | fix(web): sent messages stand out on the black canvas in the new design (#25323) | thread | yes (design) | phase 2 (design) |
| f40c7c6435 | feat(web): new design is on by default (#25324) | settings | yes (design) | phase 2 (design) |
| 70b0abceda | fix(web): short branch names no longer get clipped in thread details (#25328) | pr/git | yes | already so |
| c66f13ce97 | refactor(mobile): stream and MCP webviews tie their work to the view's lifetime (#25226) | other | no | n/a |
| aa2c80b9e3 | fix(web): stacked notices above the composer no longer cast a dark band (#25329) | composer | yes (design) | phase 2 (design) |
| 1549046fd2 | fix(web): thread undo notice sits above the bottom shelves instead of pushing the list (#25270) | sidebar | yes | ported (f4d4d618) |
| 6f3f0d46ea | feat(web): "could not load" screen tells users how to debug it (#25317) | connections | yes | ported (1f25d823) |
| 32507803da | fix(web): usage tabs no longer jump when switching to Limits (#25336) | settings | yes (design) | phase 2 (design) |
| 62245d8e3a | fix(web): composer bottom toolbar keeps its background under update notices (#25335) | composer | yes (design) | phase 2 (design) |
| 931bd53614 | chore(lint): enforce flatMapConditionalToFilterOrFail (#25082) | other | no | n/a |
| 2931461619 | chore(lint): enforce t3code/no-inline-schema-compile (#25113) | wire | no | n/a |
| d53b446284 | chore(lint): enforce oxc/no-accumulating-spread (#25114) | other | no | n/a |
| 695f5c9963 | chore(lint): enforce t3code/no-polling-loop-in-tests (#25120) | other | no | n/a |
| 433837752c | feat(web): "failed to start" screen helps users recover and report the crash (#25345) | connections | yes | ported (1f25d823) |
| 03851b8e7b | fix(web): keep large thread counts from shrinking labels (#25355) | thread | yes | ported (49772013) |
| 5a38e6b859 | fix(web): model picker no longer jumps when switching providers (#25358) | composer | yes | ported (d07c98a6) |
| fb8fc1ffd3 | refactor(web): disconnect and reconnect delays read a shared deadline instead of effect timers (#25363) | connections | no | n/a |
| 72dde22b6f | chore(lint): enforce effectFnOpportunity (#25099) | other | no | n/a |
| e1c750e7bd | fix(web): composer body ref stops re-attaching on every render (#25409) | composer | no | n/a |
| 0a20d7ea73 | fix(web): switching threads no longer delays the next thread's visit by up to 10s (#25368) | thread | yes | ported (3b91c48d) |
| cc93cc564b | revert(web): composer body ref goes back to the #25079 ref callback (#25412) | composer | no | n/a |
| a240408242 | refactor(web): file breadcrumb menus refetch on a new workspace change, not on every open (#25377) | other | yes | open |
| 1316d48b0c | fix(web): citations to older responses load their history instead of failing (#25371) | thread | yes | ported (fc007033) |
| 6ea34149bb | refactor(client): composers share one workspace snapshot refresh per provider and cwd (#25370) | composer | yes | open |
| cc0b86ddf1 | fix(server): goals stop the running turn, clear while working, no echoes (#25426) | composer | yes | ported (fbc03278) |
| 071239804e | refactor(web): pull request list remembers each answer for the next start (#25364) | pr/git | yes | open |
| 3f3c1b9bcf | refactor(web): HTML previews handle frame messages in one listener (#25456) | other | no | n/a |
| 2acc7b55cf | refactor(web): review guide runs are watched from their answers, not from mounted components (#25459) | pr/git | yes | open |
| 9d7997afc5 | refactor(web): resize drags, panel shells and the browser host own their listeners (#25464) | other | no | n/a |
| 3cb16cf165 | fix(web): find shows its match after a thread switch, and the timeline hears scrolling through one viewport signal (#25463) | thread | yes | ported (4859bd12) |
| d5a791b940 | fix(client): drafts for answered questions are cleared even when their thread is not open (#25457) | composer | yes | ported (0c5b1475) |
| 28df7a246f | refactor(web): terminal output no longer re-renders the drawer, theme search runs from handlers (#25458) | settings | yes | open |
| f0dd86f164 | fix(web): stable callbacks refresh before layout effects read them (#25489) | other | no | n/a |
| 7d3208cbea | test(web): say why the useStableCallback test renders without a router (#25493) | other | no | n/a |
| e5ea25d129 | fix(mobile): queued edits end when their run starts, wherever you are (#25468) | composer | no | n/a |
| 148d2fdc0e | refactor(web): root theme, toast and chrome sync start with the app (#25461) | other | no | n/a |
| f05c38f166 | fix(web): browser viewport resizes work without an open preview panel (#25462) | other | yes | open |
| d81757eea9 | test(web): attachment preview omission tests no longer time out on CI (#25515) | other | no | n/a |
| 7c6e85cfda | fix(web): browser history and titles show up again (#25491) | other | yes | open |
| 3f9448747b | fix(web): switching back to a thread no longer restores its tab's older title (#25521) | other | yes | ported (6b2f8e0a) |
| e6ec114128 | refactor(web): pull request page reacts to turns and sweep Escape without effects (#25523) | pr/git | no | n/a |
| b424c6e429 | fix(web): an armed pull request confirm no longer outlives its button (#25530) | pr/git | yes | ported (eeeadfd0) |
| 374e57d90b | refactor(web): provider settings and Codex setup run as explicit flows (#25524) | settings | yes | open |
| 8e1bb0376c | test(web): attachment preview omission cases check the prepared document instead of rendering each one (#25562) | other | no | n/a |
| b6994c5499 | fix(shared): pin T3 Connect cloudflared to 2026.10.4, which drops the compromised eMudhra intermediates (#25572) | connections | server-only | free with runtime |
| 278588a61a | fix(web): skill chips in chat open the same details popover as the composer (#25432) | thread | yes | ported (48da3112) |
| dd5b5401e1 | refactor(web): chat route shortcuts register once instead of rebuilding on every store change (#25366) | palette | no | n/a |
| fe507c5a1e | fix(clients): queued messages can't be edited while a question is open (#25593) | composer | yes | ported (0c2ed9a3) |
| 560ddb14d9 | feat(web): warn before adding a second Claude or Codex account (#25475) | settings | yes | ported |
| 451bb459f1 | refactor(web): running timers share one clock instead of an interval each (#25616) | thread | no | n/a |
| 4034b5f6b5 | fix(web): simplify the created pull request success row (#25613) | pr/git | yes | ported (eeeadfd0) |
| 5effca10b3 | fix(web): thread jump hints wait for their delay on every hold (#25636) | sidebar | yes | n/a: no held-modifier timer in CW |
| a54ba53a5c | fix(mobile): open threads from the local cache instead of "Thread unavailable" (#25627) | thread | no | n/a |
| 0c901edf57 | refactor(web): video previews attach listeners on their element and share one visibility observer (#25630) | thread | no | n/a |
| 6838e31b9c | fix(web): screen readers can wrap to the first and last message of a long thread (#23780) | thread | yes | ported (f80dae9d) |
| 024e593a63 | fix(client-runtime): a slow host no longer shows settings as read-only (#25526) | connections | yes | ported (f48eb038) |
| 977a18823c | refactor(mobile): pull request list records answers where they land (#25373) | pr/git | no | n/a |
| 9db433f4ba | refactor(web): settings group by concern, with General split into focused pages (#25651) | settings | yes (design) | phase 2 (design) |
| d73fd1279a | test(web): attachment preview Word and large-text tests no longer flake on CI (#25664) | other | no | n/a |
| 0b0417a56b | refactor(web): Cmd+O presses the Open in editor button instead of a per-picker listener (#25667) | other | no | n/a |
| 08bd2ec09c | test(web): PDF viewer behavior is covered by fast tests (#25699) | other | no | n/a |
| bd3287b640 | feat(web): thread state lives at the end of the timeline, not stacked on the composer (#25401) | thread | yes (design) | phase 2 (design) |
| 5432d8e723 | refactor(web): drafts promote from the draft store, not from route effects (#25615) | composer | no | n/a |
| becf853def | fix(web): PDF search finds phrases that wrap across lines (#25702) | other | yes | open |
| ed44f251d8 | feat(server): cut T3's MCP tool schemas by a third and merge 18 tools into action tools (#25423) | thread | yes | ported (49512488) |
| daa720a986 | fix(workflows): keep completed workflows reachable (#24587) | thread | yes | n/a: mobile Agents pill only (client-runtime threadSubagents.ts isn't used by apps/web) |
| 10a82e86ed | fix(web): devices agents open in background threads now show up (#25714) | other | yes | open |
| 71ba6b374c | refactor(web): optimistic chat messages leave without a timer (#25710) | composer | no | n/a |
| 6df241d23a | feat(provider): add Vercel fx as a provider (#18277) | settings | yes | open |
| 65b4a69407 | fix(web): thread details popover closes when the card moves inline (#25731) | thread | yes | open |
| f6a9315d19 | refactor(web): diff and file reveals are requests, and workspace edits refetch by construction (#25732) | pr/git | yes | open |
| 3425671a95 | feat(web): Add provider leads with first-class providers (#25753) | settings | yes (design) | phase 2 (design) |
| 8e86eb2b4d | fix(client-runtime): searches and refreshes no longer wait on an unreachable environment (#25703) | connections | yes | ported (938aa3f8) |
| 5d91ab1117 | refactor(web): command palette state lives in a store, git and branch pickers drop timer and sync effects (#25733) | palette | no | n/a |
| 83838af7ba | fix(mobile): finished subagents stay reachable from the Agents pill (#25759) | thread | yes | n/a: mobile Agents pill |
| b1619f3a74 | fix(web): cancelling update everything no longer flashes the update button's focus ring and tooltip (#25774) | sidebar | no | n/a |
| 6f6c6c14b7 | refactor(web): drop the unreachable paint-only thread timeline path (#25787) | thread | no | n/a |
| 401b01747c | chore(release): prepare v0.1.3 | other | no | n/a |
| 96fc7b9551 | refactor(web): the new design is the only design, with no toggle (#25778) | settings | yes (design) | phase 2 (design) |
| 70eccd48e4 | fix(web): keep right panel maximize available in narrow windows (#25389) | thread | yes | ported (3bc3509d); the sheet still has no maximize button |
| 2202787df0 | fix(web): onboarding import no longer hangs when the project never arrives (#25805) | settings | yes | open |
| 1a4f3c4a3c | fix(mobile): Windows image paths and non-ASCII file links open like desktop (#25802) | thread | yes | open |
| f81c4cd79f | fix(web,mobile): markdown previews no longer show YAML frontmatter as a giant heading (#25804) | other | yes | ported (7ba45ab4) |
| b333c175ba | fix(web): compact toggle shows the token count again (#25818) | composer | yes | open |
| 1702d55214 | fix(web,mobile): bot approvals are visible on the PR summary (#25829) | pr/git | yes | ported (ed18558a); avatar verdict glyph is phase 2 |
| f3b058cd6a | fix(web,mobile): stopped runs no longer look like errors (#25830) | thread | yes | open |
| e5f2e5dbbc | fix(client-runtime): iOS resume keeps live sockets and drops dead ones 4x faster (#25824) | connections | yes | open |
| 56695ae3ec | feat: model labels show the name you'd say out loud (#24205) | composer | yes | open |
| 4cb29a56f6 | fix(web): switching a file between markdown and the editor no longer saves a draft twice (#25768) | other | no | n/a |
| 92e645032c | fix(web,mobile): queued messages get a simpler Send now row, no reordering (#25846) | composer | yes | open |
| ad068d7c93 | fix(web): Steer no longer does nothing while a compaction runs (#25837) | composer | yes | open |
| 63bc022f64 | fix(web): clicking the device screen no longer draws a focus ring (#25882) | other | no | n/a |
| 7873f53ada | fix(web): the Add ChatGPT account dialog animates closed once the account connects (#25868) | settings | yes | open |
| c39a115a14 | refactor(web): composer clears scroll-collapse in render, not after paint (#25909) | composer | no | n/a |
| a4fe62ecfb | refactor(web): composer overlay re-measures from one layout effect (#25915) | composer | no | n/a |
| 3e61886a24 | refactor(web): file browser records the right-click position on its own panel (#25908) | other | no | n/a |
| 067db24e00 | refactor(web): preview element picker drops its unmount guard (#25920) | other | no | n/a |
| 2083a22919 | fix(web): PR Code tab no longer requests the diff of a commit the PR dropped (#25916) | pr/git | yes | ported (5c30b9b8) |
| 6dc4842523 | refactor(web): file tree drag mentions use React drag handlers (#25913) | other | no | n/a |
| d0b81ceb6e | fix(web): closing the last Browser tab hides the right panel again (#26058) | other | yes | already so (RightPanelState closes on the last surface) |
| 21762b5d4d | refactor(web): pull requests Cmd+F focuses the topbar search directly (#26045) | pr/git | no | n/a |
| 6369e284d7 | refactor(web): install draft model reconciliation at app start (#26046) | composer | no | n/a |
| 7b4c4b423c | refactor(web): the upload queue alone records finished file uploads on drafts (#26050) | composer | no | n/a |
| 02329327c6 | fix(clients): prompt links find projects cloned from git.cafe (#26042) | pr/git | yes | ported (42571e33) |
| 4914cdd98f | fix(web): chips drop their pill and stay readable on every theme (#25066) | composer | yes (design) | phase 2 (design) |
| 570d4b03ee | feat(mobile): report crashes to Axiom with symbolicated stacks (#19093) | other | no | n/a |
| 5808469018 | fix(web): chip palette test follows the single design (#26131) | other | no (design) | n/a |
| 888e444c1a | feat(server): t3_thread_launch takes clientRequestId (#16654) | wire | server-only | free with runtime |
| 4005759adf | feat(server): link to another environment (#16655) | connections | yes | free with runtime; client in b047c435 |
| cb988502aa | feat(server): agents use linked environments through any T3 tool (#16684) | other | server-only | free with runtime |
| 6918c35a36 | feat(server): work a linked environment starts stays within its link (#16695) | wire | yes | free with runtime |
| a6676f9a13 | feat(web,mobile): linked environments in Connections (#16698) | connections | yes | ported (b047c435) |
| 594f1ce2eb | feat(server): delegate_task to a linked environment (#16719) | thread | yes | free with runtime; delegate navigation open |
| 8b14660b27 | feat(server,web,mobile): an agent sets up a link to another environment (#17129) | connections | yes | ported (a097e0a4, a4e56409) |
| 5e9d56416f | feat(server,web,mobile): @-mention a machine, and linked environments become a Labs beta (#17130) | composer | yes | Beta switch ported (b047c435); machine @-mention open |
| bbd9593973 | feat(web): channel artwork choice on Latest, plus nightly or dev art on any channel (#26138) | settings | yes (design) | phase 2 (design) |
| 5b70d81b0d | feat(mobile): browse ZIP attachments with the shared archive reader (#19463) | other | no | n/a |
| a27ec88bfa | feat(server,web): see and stop the dev servers a thread started (#22542) | thread | yes | open |
| f08136d42d | fix(web): composer no longer jumps when a second line is added (#26155) | composer | yes (design) | phase 2 (design) |
| b31de684d2 | feat(web,mobile): queued messages show who sent them (#26159) | composer | yes | open |
| 8f0b729faf | fix(preview): agent and browser panel show the same page after a late desktop attach (#22877) | connections | no | n/a |
| 1cf14a498f | fix(web): pairing, connect, error, and Clerk sign-in surfaces match the app's dialog style (#25281) | connections | yes (design) | phase 2 (design) |
| 3b22620a5c | fix(server): parallel worktree launches no longer fail on .git/config lock (#25700) | pr/git | server-only | free with runtime |
| 33d0c9637b | chore(lint): every React effect states its reason at the call site (#26161) | other | no | n/a |
| e66ffccf49 | perf(web): stop measuring table cells while replies stream (#26152) | thread | yes | ported (0880487e) |
| dde3fdb5a6 | feat(desktop): add a remote server by clicking its t3code://pair link (#24111) | connections | yes | not ported: t3code:// belongs to the official app; CW registering it would fight T3 for the links |
| 4fc9e5f2fc | fix(web): settings avatar no longer hugs the modal corner (#26180) | settings | yes (design) | phase 2 (design) |
| 294981fa72 | fix(mobile): Windows paths in messages keep their backslashes (#21454) | thread | no | n/a |
| 7e884b2df6 | feat: triage an issue from the command palette, no terminal needed (#22753) | palette | yes | open |
| c38b265adc | feat(web): filter the sidebar by several projects at once (#25284) | sidebar | yes | open |
| 06d4b57fa6 | fix(web): composer strip drops the folder icon next to the machine icon (#26158) | composer | yes (design) | phase 2 (design) |
| 7e713926cd | feat(web): background work line shows the newest activity, no dots (#25299) | thread | yes | open |
| 4ab7084aa7 | feat(web,mobile): the @ picker lists threads on linked machines (#26201) | composer | yes | open |
| 0affd28db2 | feat(web,mobile): Copy thread copies a chip that works on linked machines (#26202) | thread | yes | open |
| 2525252c96 | feat(web): F6 moves between workspace areas, and the sidebar is keyboard navigable (#25877) | sidebar | yes | open |
| e2a8ef0174 | feat(dev): test turns in the UI for free with a replay provider (#26207) | other | no | n/a |
| 93a9e079b1 | feat(threads): choose your own snooze options in settings (#26208) | settings | yes | open |
| 3b2f958603 | fix(server): ACP Registry searches reuse a recently fetched index (#26248) | settings | server-only | free with runtime |
| 67661cfbb5 | chore: delete 18k lines of code that nothing reaches (#26238) | other | no | n/a |
| e0b3cfe666 | fix(web): image and file chips underline their name on hover again (#26252) | composer | yes (design) | phase 2 (design) |
| 91992bd5d4 | fix(web): update dialog shows one row per machine (#26210) | settings | yes | open |
| 8947f3e353 | fix(web): server rows keep their source visible, cmd-click opens your browser (#26267) | thread | yes | open |
| c2fbf0a524 | feat(server,web,mobile): thread links name their environment and never a title (#26239) | thread | yes | ported (7616fc6e) |
| fe55faf379 | fix(clients): # suggestions put linked pull requests first for text queries (#26269) | composer | yes | ported (4cf7cdc6) |
| 49a9e80e0b | fix(terminal): keep shared terminal grids in sync (#24352) | wire | yes | ported (40182582) |
| 0c80751701 | feat: sign in to GitHub through the T3 Code for GitHub app [internal testing only] (#26245) | settings | yes | open |
| 9910c0e874 | perf: reduce remote reconnect and command delays (#25754) | connections | yes | already so (wire audit) |
| 3ef1610079 | fix(web): compaction row says "Compacting for 12s" instead of "after being idle" (#26299) | thread | yes | open |
| 9c6429d74b | fix(web): threads without a project start on the primary environment (#26301) | palette | yes | ported (9a1ab655) |
| cafdcdaacd | fix(clients): give image attachment chips a blue accent (#26306) | composer | yes (design) | phase 2 (design) |
| afc233492d | fix(web): prevent image thumbnails from warping during repaints (#26308) | thread | no | n/a |
| 49582b7b2a | test(web): attachment font and large-text preview tests wait for the real load (#26314) | other | no | n/a |
| 1f8530ec3c | feat(web): pending approvals show on their timeline row (#26255) | thread | yes | open |
| 9b052a2d5b | fix(web): show the platform modifier in the send tooltip (#22436) | composer | yes | ported (0319f265) |
| feb49e78d0 | fix(web): let theme color pickers use popover glass (#22348) | settings | yes (design) | phase 2 (design) |
| 003ccd336d | fix(client-runtime): pairing links can no longer add routes to a saved environment (#26178) | connections | yes | ported (b089670b) |
| feb2e32de6 | fix(web): align sidebar button geometry with shared tokens (#22287) | sidebar | yes (design) | phase 2 (design) |
| 8e76f945d2 | feat(relay): T3 Chat Pro and Premier accounts get more tunnels (#25931) | connections | yes | open |
| 50d3a31ffd | fix: guests see the screenshots the agent shows in its replies (#26323) | thread | server-only | free with runtime |
| 4e4d4ba395 | feat(web): boring sidebar groups threads into project folders (#21039) | sidebar | yes | open |
| cadbdafc06 | test(web): attachment preview tests wait long enough for cold workers and fonts (#26342) | other | no | n/a |
