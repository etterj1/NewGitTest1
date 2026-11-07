# TaskHub

TaskHub is a native SwiftUI app for **macOS and iOS**. It puts everything that's being asked of you into one list, pulled from:

| App | What shows up | Create | Edit | Mark done |
|---|---|---|---|---|
| **ClickUp** | Open tasks assigned to you in every workspace | ✅ into any list | ✅ title, description, due date and time, priority | ✅ moves the task to the list's closed status |
| **Asana** | Incomplete tasks assigned to you in every workspace | ✅ into My Tasks or a project | ✅ title, notes, due date and time | ✅ |
| **Slack** | Messages that @mention you in the last 14 days (the search is customisable) | — | — | ✅ adds a ✅ reaction |
| **Gmail** | Starred emails (any Gmail search works) | — | — | ✅ un-stars and archives |
| **Google Calendar** | Upcoming events (declined ones are hidden) | ✅ | ✅ title, notes, start | hides the event in TaskHub only |
| **Google Tasks** | Every task list | ✅ | ✅ title, notes, due date | ✅ |
| **Apple Reminders** | Every Reminders account on the device | ✅ | ✅ title, notes, due date and time, priority | ✅ |
| **Apple Calendar** | Every calendar account on the device | ✅ | ✅ | hides the event in TaskHub only |
| **TaskHub Inbox** | Quick notes and to-dos stored only in TaskHub | ✅ | ✅ | ✅ |

**Multiple accounts:** you can connect as many accounts per service as you need, for example two ClickUp logins, a work Gmail and a personal Gmail, and several Slack workspaces. Each account can be renamed, paused, or set to show only some of its sources.

### Features
- **Smart views:** Today (includes overdue items), Next 7 Days, Overdue, All Open, No Date, and Completed. You can also browse by app, project, or account.
- **Search** across titles, notes, projects, and the person who asked.
- **Two-way sync:** your edits are sent straight to the source app's API. If one fails, the change is rolled back and you see an error.
- **Auto-refresh** runs every 5 minutes and whenever the app comes to the foreground. Pull to refresh on iOS, or press ⌘R.
- **Mac extras:** a menu-bar panel showing today's items, ⌘N for a new task, and accounts under Settings (⌘,).
- **Offline cache:** the last synced list shows immediately when the app opens.
- **Privacy:** tokens are kept in the Keychain. The app talks directly to each service, with no server in between.

> **About "notes":** Apple Notes has no public API, so it can't be connected. For quick notes, use the **TaskHub Inbox** or **Apple Reminders**. Notion could be added as a connector later.

---

## Getting it running

You need a Mac with **Xcode 15.3 or later** and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
git clone <this repo> && cd NewGitTest1
cp Config.xcconfig Config.local.xcconfig   # then edit it (it's git-ignored)
xcodegen generate
open TaskHub.xcodeproj
```

In `Config.local.xcconfig`, set `DEVELOPMENT_TEAM` to your Apple Team ID. Add the Google values too (see below). Then pick the **TaskHub-macOS** or **TaskHub-iOS** scheme and run it.

> Rerun `xcodegen generate` whenever you add or remove source files.

### 1. Google (Gmail, Calendar, Tasks): one-time setup
1. In [Google Cloud Console](https://console.cloud.google.com/), create a project.
2. Under **APIs & Services → Library**, enable the **Gmail API**, **Google Calendar API** and **Google Tasks API**.
3. Under **OAuth consent screen**, choose **External** (or **Internal** if every account is in your Google Workspace) and add the scopes for Gmail (modify), Calendar, and Tasks. Add each Google address you'll sign in with as a **test user**.
4. Under **Credentials → Create credentials → OAuth client ID**, choose the **iOS** application type and use the bundle ID `com.jasonetter.taskhub`. The same client works for the Mac app.
5. Copy the client ID into `Config.local.xcconfig`:
   ```
   GOOGLE_CLIENT_ID = 1234567890-abc123.apps.googleusercontent.com
   GOOGLE_REVERSED_CLIENT_ID = com.googleusercontent.apps.1234567890-abc123
   ```

> ⚠️ While the consent screen is in **Testing** mode, Google expires refresh tokens after 7 days, so you'd have to sign in again every week. For personal use, click **Publish app** on the consent screen. You'll see an "unverified app" warning when signing in, but the tokens stop expiring. With a Google Workspace account, choosing **Internal** avoids both problems.

### 2. ClickUp
In ClickUp go to **Settings → Apps → API Token → Generate**. In TaskHub, choose **Add Account → ClickUp** and paste the `pk_…` token. Do this once for each ClickUp login.

### 3. Asana
In Asana go to **My Settings → Apps → Manage Developer Apps → Personal access token**. In TaskHub, choose **Add Account → Asana** and paste the token.

### 4. Slack (once per workspace)
1. At [api.slack.com/apps](https://api.slack.com/apps), choose **Create New App → From scratch** and pick the workspace.
2. Under **OAuth & Permissions → User Token Scopes**, add `search:read` and `reactions:write`.
3. Click **Install to Workspace**, then copy the **User OAuth Token** (`xoxp-…`).
4. In TaskHub, choose **Add Account → Slack** and paste the token.

To change which messages count as asks, open the account and edit **Slack search**, e.g. `<@{me}> after:{since}` or `to:me is:unread`.

### 5. Apple Reminders and Calendar
Choose **Add Account → Apple** and allow access. Every account already set up on the device (iCloud, Exchange, Google, …) is included.

---

## Project layout

```
project.yml                 XcodeGen spec (iOS + macOS targets)
Config.xcconfig             Team ID / Google client ID placeholders (override in Config.local.xcconfig)
TaskHub/
  App/TaskHubApp.swift      App entry, Mac Settings window and menu bar extra
  Models/                   TaskItem, Account, TaskSource (capabilities per app)
  Services/                 HTTP helper, Keychain, JSON persistence, Google OAuth (PKCE)
  Providers/                One connector per service, all implementing `TaskProvider`
  Store/AppStore.swift      Merges all accounts, filtering, optimistic sync, persistence
  Views/                    Sidebar, list, detail editor, new task, accounts, menu bar
```

### Adding another service (e.g. Notion, Jira, HubSpot)
1. Add a case to `AccountKind` and `TaskSource` in `Models/TaskSource.swift`.
2. Create a `TaskProvider` in `Providers/`. It implements `fetchItems`, plus `destinations`, `create`, `update` and `setCompleted` where the service supports them.
3. Register it in `ProviderFactory`, then add its connect step to `AddAccountView`.

## Current limitations and possible next steps
- **Each device connects its own accounts.** Accounts and Inbox tasks aren't synced between your Mac and iPhone yet. CloudKit would be the natural way to add that.
- ClickUp, Asana and Slack use personal tokens rather than a full OAuth flow. That's simpler for a personal tool, but sharing the app with a team would need OAuth.
- Slack "done" state is the ✅ reaction plus a local record, because Slack search can't filter by your own reactions.
- Ideas for later: home-screen and Notification Center widgets, due-date notifications, Notion as the "notes" source, and AI triage (e.g. "summarise what clients asked me for this week").
