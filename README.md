# ShotCal

A macOS menu bar app. Press a shortcut, drag over an event on screen, and the
event is read by Claude and added to Google Calendar.

**Status:** all four stages are built.

| Stage | What | State |
| --- | --- | --- |
| 1 | Menu bar app, global hotkey, region capture | done |
| 2 | Claude extraction to structured event data | done |
| 3 | Google OAuth and event creation | done |
| 4 | Notification actions (Open, Undo), full settings, launch at login | done |

Until Google is connected, a capture ends in a preview: the notification shows
what would be added, titled "Preview, not saved".

## Requirements

- macOS 14 or later
- Xcode (the full app, not only the Command Line Tools)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- An Apple Development signing identity. Check with
  `security find-identity -v -p codesigning`.

## Build and run

```sh
make run      # generate the project, build, verify the signature, launch
make test     # unit tests
make build    # build only
make install  # optimised build into /Applications, then launch it
make clean    # remove build output and the generated project
```

The Makefile calls `xcodegen` and `xcodebuild`. If `xcode-select` points at the
Command Line Tools, it uses `/Applications/Xcode.app` for these commands and
leaves the system setting alone. The built app is
`build/Build/Products/Debug/ShotCal.app`.

`ShotCal.xcodeproj` is generated from `project.yml` and is not checked in. To
work in Xcode, run `make gen` and open it.

### Signing

The app is signed with the `Apple Development` identity for team `375L8HDHKR`,
and the bundle ID is fixed at `com.koreneff.ShotCal`. Both are set in
`project.yml`. macOS ties the Screen Recording grant and the Keychain items to
that pair, so an ad-hoc signature or a new bundle ID would make it ask again
after every build. `make build` fails if the result is not signed this way.

## First run

ShotCal opens a window for its two permissions:

1. **Screen Recording.** Click *Open Screen Recording Settings*, switch ShotCal
   on, then click *Relaunch ShotCal*. macOS applies the grant only to a fresh
   launch.
2. **Notifications.** Click *Allow Notifications*.

The same window is under *Permissions…* in the menu. Then open *Settings…*:

1. Paste your Anthropic API key and click *Save Key*.
2. Paste the Google **Client ID** and **Client secret** (from
   [Google Cloud setup](#google-cloud-setup)) and click *Connect Google*. Your
   browser opens Google's sign-in. Approve it, and the status changes to
   *Connected*.

### Connecting Google Calendar

The sign-in is OAuth 2.0 for desktop apps with PKCE. ShotCal opens the system
browser and listens on `http://127.0.0.1` on a random port for Google's
redirect. The listener accepts connections from this Mac only and closes when
the sign-in ends or after five minutes. The only scope requested is
`https://www.googleapis.com/auth/calendar.events`.

Events go to the calendar named in *Calendar ID*. The default, `primary`, is the
account's main calendar. To keep captured events apart, create a calendar in
Google Calendar (for example "ShotCal"), open its settings, copy the
**Calendar ID** under *Integrate calendar* (it ends in
`@group.calendar.google.com`) and paste it into Settings.

*Disconnect* removes the saved sign-in and asks Google to revoke it. If Google
stops accepting the sign-in, the menu shows *Reconnect Google…*.

## Using it

Press **Ctrl+Opt+Cmd+C** (or choose *Capture Event* from the menu), drag over
the event, and release. Esc cancels. The menu bar icon becomes a spinner while
Claude reads the image, and a notification shows the result. The icon also shows
a checkmark or a warning triangle for a few seconds afterwards, and the menu
keeps the last result, so the outcome is visible even when a Focus mode holds
the notification back.

### Open and Undo

The "Added" notification has two buttons. macOS shows them when you hover over
the banner and click *Options*, or directly if ShotCal's notification style is
set to *Alerts* in System Settings.

- **Open** shows the event's page in Google Calendar. Clicking the notification
  itself does the same. A capture with several events opens the first.
- **Undo** deletes the event, or all events from that capture, and confirms with
  a "Removed" notification.

Both work from Notification Center later on, also after ShotCal has been
restarted. The menu has *Open Last Event* and *Undo Last Event* for the most
recent capture.

### Shortcut and launch at login

In *Settings…* under *General*, click the shortcut, then press the new
combination. It needs at least one of ⌃, ⌥ and ⌘. If another app already holds
the combination, ShotCal says so and keeps the old one. *Reset* returns to
Ctrl+Opt+Cmd+C.

*Launch at login* registers the running copy of ShotCal as a login item. Run
`make install` first and switch it on in the copy in `/Applications`; the copy
in `build/` is deleted by `make clean`. The installed copy has the same bundle
ID and signature, so it keeps the Screen Recording permission and the Keychain
items.

### How the capture is taken

ShotCal runs `/usr/sbin/screencapture -i -x -c`, which puts the selection on the
clipboard. It then moves the image into a temp file, puts back whatever was on
the clipboard before, and deletes the temp file when the run ends. A clipboard
manager may still record the screenshot for a moment.

The clipboard detour exists because `screencapture` asks Spotlight about a file
five times before saving it. When Spotlight is slow to answer, each query takes
ten seconds and every capture stalls for almost a minute. If Spotlight is
healthy on your Mac (`time mdls /Applications/Safari.app` returns at once) and
you would rather not have the clipboard touched, switch to writing the file
directly:

```sh
defaults write com.koreneff.ShotCal captureToFile -bool YES
```

## Testing each stage

**Stage 1, capture only.** Before you save an API key, a capture ends with the
notification "Screenshot captured, but there's no API key" and the size of the
image, which confirms the hotkey and the capture. To inspect the file itself:

```sh
defaults write com.koreneff.ShotCal keepCaptures -bool YES   # keep the temp files
log stream --info --predicate 'subsystem == "com.koreneff.ShotCal"'
```

The log prints the path of each kept file. Turn it off again with
`defaults delete com.koreneff.ShotCal keepCaptures`.

**Stage 2, extraction.** After a capture, *Copy Last Result as JSON* in the menu
copies what Claude returned, and the `log stream` command above prints it. To
run an image file through the same code without the hotkey:

```sh
make extract IMG=~/Desktop/some-screenshot.png
```

This prints the JSON and the resolved dates. It reads the API key from the
Keychain, or from `ANTHROPIC_API_KEY` if the Keychain has none.

**Stage 3, Google Calendar.** Once *Settings* shows *Connected*, a capture ends
with the notification "Added: …" and the event is in the calendar. To check the unhappy paths: a wrong Calendar ID gives a
notification naming the ID, and removing ShotCal's access at
<https://myaccount.google.com/connections> makes the menu offer
*Reconnect Google…* at the next capture, within an hour.

**Stage 4, actions and settings.** Capture an event, choose *Undo* on the
notification and check that the event is gone from the calendar. Capture again
and choose *Open*. Record a different shortcut in Settings and capture with it.
After `make install`, switch on *Launch at login*, log out and in, and check
that the icon is in the menu bar.

## How the extraction works

- One request to the Messages API with plain `URLSession`, model
  `claude-haiku-5-5` (editable in Settings), `output_config.effort` set to
  `low`, and structured outputs (`output_config.format` with a JSON schema).
  No `temperature`, `top_p` or `top_k` is sent; the API rejects them.
- The image is scaled so its long edge is at most 1600 px.
- The system prompt states today's date, weekday, local time and time zone,
  and lists the next 14 days with their weekdays, so "ensi tiistaina" and
  "huomenna klo 14" resolve correctly.
- If a model rejects the structured request, ShotCal asks for plain JSON
  instead, validates it, and retries once if it does not parse.

The schema:

```
{ events: [ { title, start, end?, all_day, year_given, location?, description? } ],
  reason_if_none? }
```

`year_given` is an addition to the original spec. It is false when the
screenshot showed no year. `EventDateResolver` uses it to move a date that
landed in the past to its next occurrence, so that rule holds even if the model
gets the year wrong. The same file applies the one-hour default and converts
all-day ranges to the exclusive end date calendars expect. Its tests are in
`ShotCalTests/EventDateResolverTests.swift`.

## Secrets

Four items are stored in the login Keychain under the service
`com.koreneff.ShotCal`: the Anthropic API key, the Google client ID, the Google
client secret, and the Google refresh token. The Google access token is kept in
memory only and fetched again after a relaunch. The model ID, calendar ID,
shortcut and other plain settings are in UserDefaults. A notification carries
the IDs and link of the events it announced, so that Undo and Open work later. Nothing secret is in the repository.

## Project layout

```
project.yml            XcodeGen project definition, signing settings
ShotCal/Core/          Logic with no UI: Claude client, prompt and schema,
                       date resolution, image scaling, region capture,
                       Google sign-in and Calendar client
ShotCal/App/           Menu bar item, hotkey and recorder, pipeline,
                       notifications, login item, settings and permissions
                       windows, --extract command
ShotCalTests/          Unit tests; compiles ShotCal/Core directly
```

## Google Cloud setup

You end up with a client ID and a client secret for a desktop OAuth client,
which go into ShotCal's Settings. Google renames these console pages from time to time;
the names below are from its current guides.

1. Go to <https://console.cloud.google.com>, and create a project (for example
   "ShotCal").
2. Enable the calendar API: *APIs & Services > Library*, search for
   **Google Calendar API**, click **Enable**.
3. Configure the consent screen: *Menu > Google Auth platform > Branding*, click
   **Get Started**.
   - App name and support email: anything, for example "ShotCal" and your address.
   - Audience: **External**. (Internal exists only for Google Workspace
     organisations.)
   - Contact email, agree to the data policy, **Create**.
4. Add the scope: *Data Access > Add or Remove Scopes*, add
   `https://www.googleapis.com/auth/calendar.events`, **Save**. This is the only
   scope ShotCal requests.
5. Add yourself as a tester: *Audience > Test users > Add users*, enter the
   Google account whose calendar you want to use.
6. Create the client: *Google Auth platform > Clients > Create Client*,
   application type **Desktop app**, any name, **Create**. Copy the client ID
   and the client secret straight away, or download the JSON.

One thing to decide in step 5: while the app's publishing status is *Testing*,
Google expires refresh tokens after 7 days, so ShotCal would ask you to
reconnect every week. Publishing the app (*Audience > Publish app*) removes that
limit. For a personal app you do not need to go through verification; Google
shows an "unverified app" warning once when you connect, which you can click
through.

Desktop clients may redirect to `http://127.0.0.1` on any port without
registering a redirect URI, which is what ShotCal's sign-in uses.

## Troubleshooting

- **The screenshot only shows the desktop picture.** Screen Recording is not
  granted, or ShotCal was not relaunched after granting it.
- **Nothing happens for about a minute after selecting.** Only in
  `captureToFile` mode, when Spotlight is slow. Delete that setting
  (`defaults delete com.koreneff.ShotCal captureToFile`) or fix Spotlight.
- **The shortcut does nothing.** Another app owns the combination. The menu
  says so when registration failed. Record a different one in Settings.
- **No Open or Undo buttons.** Hover over the banner and click *Options*, or use
  *Open Last Event* and *Undo Last Event* in the menu.
- **Launch at login stopped working.** The login item points at a copy of the
  app that has moved or been deleted. Switch it off and on in the copy you use.
- **No notification appears.** A Focus mode silences ShotCal unless you add it
  under *System Settings > Focus > (your Focus) > Allowed Apps*. Silenced
  notifications still land in Notification Center. Also check
  *System Settings > Notifications > ShotCal*.
- **Google says "Access blocked" when connecting.** The app is in *Testing* and
  the account is not listed under *Audience > Test users* (step 5).
- **"Google rejected the client ID or client secret".** One of the two was
  pasted wrong, or the client is not of the type *Desktop app*.
- **"Google Calendar API has not been used in project…".** The API is not
  enabled in the Cloud project (step 2).
- **"Google has no calendar with the ID…".** The Calendar ID in Settings is not
  one this account can write to.
- **The menu shows *Reconnect Google…*.** Google stopped accepting the saved
  sign-in: access was removed, or the app is in *Testing* and seven days passed.
- **Checking what happened.** Key steps are logged:
  `log show --last 10m --predicate 'subsystem == "com.koreneff.ShotCal"'`
