# Redesign settings layout

The user called T3's settings layout confusing: twelve pages in T3's order, and a General page that mixes the composer, diffs, notifications, sidebar sorting, updates, background probes, confirmations and About in one long scroll. Under Redesign (Dither) Settings now has sections named after what a person wants to change, each one short page with a title, a one-line description and a few groups, after Capy's settings (General, Notifications, Models, Projects & setup, each with a description under the title).

Other themes keep T3's pages and nav unchanged. The section list and slices live in `Features/Settings/DitherSettingsLayout.swift`.

## How it works

A section shows slices of T3's pages: a whole page, or some of a page's groups with some of their rows, sometimes under a new title. The rows are T3's own views, bound to the same keys, so stored settings, the wire and search ids don't change. A slice that shows part of a page gets its own copy of the page; whole pages are the shared ones. The scope picker shows once per section, above its server settings, and not on device-only sections like Notifications.

Search and deep links land in the section that shows the setting: `DitherSettingsSection.home(of:anchor:)`, checked for every General and Storage search result by `DitherSettingsLayoutTests`.

## Sections

| Section | What it shows |
|---|---|
| General | Composer and chat (time format, response streaming, slash menu skills, rich text, collapse on scroll, send shortcut, follow-ups), Diffs and panels, Confirmations |
| Appearance | T3's Appearance page |
| Notifications | Alerts: system and in-app notifications |
| Keyboard | T3's Keybindings page |
| Models and providers | New threads' model and permissions, the text generation model, then T3's Providers page |
| Threads | Sidebar (grouping, order, working section, auto-settle), Usage limits (auto-resume, snooze, compact idle Claude threads), Archived threads |
| Scheduled tasks | T3's Scheduled Tasks page |
| This project | T3's Project page, only while a project is picked in the scope |
| Projects and worktrees | New threads' workspace and submodules, new worktrees from remote, Add Project's folder, Worktree location and cleanup |
| Git and pull requests | T3's Source Control page |
| Browser and devices | T3's Integrations page, then SnapShots |
| Machines and connections | T3's Connections page |
| Advanced | Background work (provider version checks, continue after restarts, background activity), Diagnostics, Legacy features, Storage's database, cleanup, artifacts and logs |
| About | Version and updates: version, server runtime, update track, mobile app, privacy policy, open source licenses |

## Old page to new section

| T3 page | Redesign section |
|---|---|
| Project | This project |
| General > New threads | Models and providers (model, permissions), Projects and worktrees (workspace, submodules) |
| General > Organization | Threads (Sidebar, Usage limits) |
| General > Behavior | General (Composer and chat, Diffs and panels), Notifications, Advanced (Background work) |
| General > Projects & threads | Projects and worktrees |
| General > Confirmations | General |
| General > Text generation | Models and providers |
| General > About | About |
| General > Diagnostics | Advanced (View diagnostics), About (licenses) |
| General > Legacy features | Advanced |
| Appearance | Appearance |
| Keybindings | Keyboard |
| SnapShots | Browser and devices |
| Providers | Models and providers |
| Integrations | Browser and devices |
| Scheduled Tasks | Scheduled tasks |
| Source Control | Git and pull requests |
| Storage > Worktrees | Projects and worktrees |
| Storage > Database, Cleanup, Artifacts and logs | Advanced |
| Connections | Machines and connections |
| Archive | Threads |
| Diagnostics, Open source licenses | Own pages, Escape goes back to Advanced and About |
