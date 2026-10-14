<p align="center">
  <img src="Icon/AppIcon.png" width="128" alt="GitHub Float icon">
</p>

<h1 align="center">GitHub Float</h1>

<p align="center">
  <b>Your GitHub Project's code reviews, always on top of your screen.</b><br>
  A tiny native macOS floating panel that shows what you put in review, who is reviewing it, and which teammates' PRs still need a reviewer.
</p>

<p align="center">
  <a href="https://github.com/vinimcorrea/github-float/releases/latest"><img src="https://img.shields.io/github/v/release/vinimcorrea/github-float?style=flat-square" alt="Release"></a>
  <a href="https://github.com/vinimcorrea/github-float/releases"><img src="https://img.shields.io/github/downloads/vinimcorrea/github-float/total?style=flat-square" alt="Downloads"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-black?style=flat-square&logo=apple" alt="macOS 13+">
  <img src="https://img.shields.io/badge/Swift-SwiftUI-F05138?style=flat-square&logo=swift&logoColor=white" alt="Swift">
  <a href="https://github.com/vinimcorrea/github-float/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/vinimcorrea/github-float/ci.yml?style=flat-square&label=build" alt="Build"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/vinimcorrea/github-float?style=flat-square" alt="MIT License"></a>
  <a href="https://github.com/vinimcorrea/github-float/stargazers"><img src="https://img.shields.io/github/stars/vinimcorrea/github-float?style=flat-square" alt="Stars"></a>
</p>

<p align="center">
  <img src="docs/social-preview.png" width="820" alt="GitHub Float screenshot">
</p>

---

## Why?

Your PR sits in **In Review** for two days because nobody noticed it. A teammate's PR waits for a reviewer while you're heads-down. You keep switching to the browser to check the board.

**GitHub Float** keeps your [GitHub Project](https://docs.github.com/issues/planning-and-tracking-with-projects) review flow in a small glass panel that floats above every window, on every Space, even over full-screen apps. Glance, don't switch.

## ✨ Features

- 🪟 **Always on top**: a non-activating floating panel that never steals focus, visible on all Spaces and over full-screen apps.
- 👤 **Mine**: your tasks grouped by status (In Progress, In Review, Reviewed), each with its linked PRs.
- 👀 **Reviewing**: the tasks you are reviewing for teammates, split into *Your turn* and *Waiting on the author*, with a notification when a re-review is requested.
- 🔍 **Review state at a glance**: *awaiting review*, *being reviewed*, *changes requested*, *approved*, *merged*, plus the reviewers and CI status (✅ ❌ ⏳).
- 🙋 **Needs reviewer**: teammates' tasks in review with no second assignee, so you can pick one up in one click.
- ⏱️ **Time in status**: an age badge turns orange after 24h and red after 72h.
- 🔔 **Native notifications** when something needs you: a new review, changes requested, approval, failing CI, merged PR, a task moved forward, or a new task waiting for a reviewer.
- ⚡ **Efficient**: one GraphQL request per poll for all tabs. Polling pauses while your Mac sleeps or is locked and backs off on errors.
- 🧩 **Compact mode**: collapse to a single line with your counts.
- 🔐 **Private**: no server and no telemetry. It only talks to `api.github.com` with your own token.
- 🪶 **Native and tiny**: Swift + SwiftUI, a few MB, no Electron.

| Mine | Reviewing | Needs reviewer |
|---|---|---|
| <img src="docs/mine.png" width="260"> | <img src="docs/reviewing.png" width="260"> | <img src="docs/needs-reviewer.png" width="260"> |

<p align="center"><img src="docs/collapsed.png" width="300" alt="Collapsed"></p>

## 📦 Install

### Homebrew

```bash
brew install --cask vinimcorrea/tap/github-float
```

Upgrade with `brew upgrade --cask github-float`.

### Download

1. Download **GitHubFloat.zip** from the [latest release](https://github.com/vinimcorrea/github-float/releases/latest) and unzip it.
2. Move **GitHubFloat.app** to `/Applications`.
3. The app is ad-hoc signed (not notarized), so on first launch **right-click → Open**, or run:
   ```bash
   xattr -dr com.apple.quarantine /Applications/GitHubFloat.app
   ```

### Build from source

Requires Xcode 15+ / Swift 5.9+.

```bash
git clone https://github.com/vinimcorrea/github-float.git
cd github-float
./build.sh            # builds and installs ~/Applications/GitHubFloat.app
open ~/Applications/GitHubFloat.app
```

## 🚀 Setup

1. **Authenticate.** GitHub Float uses, in order: `GH_TOKEN`, `GITHUB_TOKEN`, or your [GitHub CLI](https://cli.github.com) login (`gh auth token`).
   The easiest way is:
   ```bash
   gh auth login
   gh auth refresh -s read:project
   ```
   With a personal access token (classic), use the scopes `read:project` and `repo` (or `public_repo`).
2. **Connect a project.** On first launch, paste your project URL, e.g.
   `https://github.com/orgs/my-org/projects/12` or `https://github.com/users/me/projects/3`.
   You can change it at any time from the `⋯` menu → **Connect a Project…** (⌘,).

Your project needs a single-select **Status** field (the default in GitHub Projects). The statuses shown in *Mine* and the status that means "in review" can be changed from the menu.

## 🧠 How it works

| Tab | Shows |
|---|---|
| **Mine** | Items assigned to you whose Status is one of the selected statuses (default: *In Progress*, *In Review*, *Reviewed*), excluding the ones you are reviewing. |
| **Reviewing** | Items assigned to you where someone else authored the linked PR (or, without a PR, is the first assignee), while the PR is still open. *Your turn* means you have not reviewed yet or a re-review was requested. |
| **Needs reviewer** | Open items in the review status (default: *In Review*) **not** assigned to you that have fewer than 2 assignees. The convention: the author is the first assignee, and a reviewer adds themselves as the second one. |

Review stage of each linked PR: merged/closed → draft → approved / changes requested → being reviewed (a review was submitted) → awaiting review (reviewers requested) → no reviewers. Bot reviews and the author's own comments are ignored.

## ⌨️ Shortcuts

| Keys | Action |
|---|---|
| ⌘1 / ⌘2 / ⌘3 | Switch between *Mine*, *Reviewing* and *Needs reviewer* |
| ⌘R | Refresh now |
| ⌘, | Connect a project |
| Click a row | Open the issue or PR in your browser |

The menu bar item shows `mine · open` counts. From the `⋯` menu you can also set the poll interval, the opacity, notifications and sound, and launch at login.

## 🛠️ CLI helpers

```bash
GitHubFloat.app/Contents/MacOS/GitHubFloat --dump              # print the current board data as text
GitHubFloat.app/Contents/MacOS/GitHubFloat --notify-test       # send a test notification
.build/release/GitHubFloat --screenshots docs                  # regenerate README screenshots with demo data
```

## 🗺️ Roadmap

- [ ] Multiple projects
- [ ] Custom tab filters (any Projects filter query)
- [x] Homebrew cask
- [ ] Notarized builds
- [ ] Keyboard navigation inside the list

Have an idea? [Open an issue](https://github.com/vinimcorrea/github-float/issues/new/choose).

## 🤝 Contributing

PRs are welcome! See [CONTRIBUTING.md](CONTRIBUTING.md). The whole app is about 2k lines of Swift in `Sources/GitHubFloat`.

## 📄 License

[MIT](LICENSE) © Vinicius Correa

---

<p align="center">If GitHub Float saves you a few context switches, please <b>⭐ star the repo</b>. It helps others find it.</p>
