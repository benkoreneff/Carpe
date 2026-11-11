# Carpe

A macOS menu bar app. Press a shortcut, drag over an event on screen, and the
event is read by Claude and added to Apple Calendar or Google Calendar.

**Status:** all four stages are built.

| Stage | What | State |
| --- | --- | --- |
| 1 | Menu bar app, global hotkey, region capture | done |
| 2 | Claude extraction to structured event data | done |
| 3 | Google OAuth and event creation | done |
| 4 | Notification actions (Open, Undo), full settings, launch at login | done |

Events are saved to one calendar service, chosen at first run and under
*Settings… > Calendar service*:

- **Apple Calendar** saves through the Calendar app, so it reaches every account
  set up there. It needs the Calendars permission and nothing else.
- **Google Calendar** talks to Google directly and needs your own OAuth client
  (see [Google Cloud setup](#google-cloud-setup)). Until Google is connected, a
  capture ends in a preview: the notification shows what would be added, titled
  "Preview, not saved".

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
make release  # notarized Carpe-<version>.dmg for other Macs, see below
make clean    # remove build output and the generated project
```

The Makefile calls `xcodegen` and `xcodebuild`. If `xcode-select` points at the
Command Line Tools, it uses `/Applications/Xcode.app` for these commands and
leaves the system setting alone. The built app is
`build/Build/Products/Debug/Carpe.app`.

`Carpe.xcodeproj` is generated from `project.yml` and is not checked in. To
work in Xcode, run `make gen` and open it.

### Signing

The app is signed with the `Apple Development` identity for team `375L8HDHKR`,
and the bundle ID is fixed at `com.koreneff.carpe`. Both are set in
`project.yml`. macOS ties the Screen Recording grant and the Keychain items to
that pair, so an ad-hoc signature or a new bundle ID would make it ask again
after every build. `make build` fails if the result is not signed this way.

## Releasing to other Macs

`scripts/release.sh` (or `make release`) produces `dist/Carpe-<version>.dmg`,
which opens on any Mac with macOS 14 or later without a warning.
[INSTALL.md](INSTALL.md) is the guide to send along with it.

One-time setup:

1. A **Developer ID Application** certificate in the keychain (Xcode >
   Settings > Accounts > Manage Certificates).
2. A notarization profile named `carpe-notary`. The script never sees the
   Apple ID or its password, so create the profile yourself:

   ```sh
   xcrun notarytool store-credentials "carpe-notary" \
       --apple-id "YOUR_APPLE_ID_EMAIL" --team-id "375L8HDHKR"
   ```

   It asks for an app-specific password. Make one at
   <https://account.apple.com> under *Sign-In and Security > App-Specific
   Passwords*. `notarytool` keeps it in the login Keychain.

What the script does, stopping at the first step that fails:

1. Checks the certificate and that the notarization profile signs in.
2. Runs `scripts/check-secrets.sh`: looks for API keys, client secrets and
   tokens in every file git tracks or would track, and in every commit.
3. Builds the Release configuration as a universal binary (Apple silicon and
   Intel), signed with the Developer ID certificate, the hardened runtime and a
   secure timestamp. The development signing in `project.yml` is overridden for
   this build only.
4. Checks the result: signature, hardened runtime, timestamp, the calendar
   entitlement, no `get-task-allow`, both architectures.
5. Runs the secret check again on the app bundle, the executable included.
6. Has Apple notarize the app and staples the ticket to it, so the app also
   opens on a Mac that is offline.
7. Packs the app and an Applications shortcut into the disk image, signs it,
   has Apple notarize that too, staples it, and asks Gatekeeper for its verdict
   on both.

`scripts/release.sh --skip-notarization` does everything except Apple's part
and names the image `-unnotarized`, to try the build. Other Macs refuse to open
that one.

The version is `MARKETING_VERSION` in `project.yml`. It is in the disk image's
name and in Carpe's menu, on the grey line above *Quit Carpe*.

`scripts/check-secrets.sh` also runs by itself (`make check-secrets`). It
prints only the first characters of a match. A file that git ignores, such as a
downloaded `client_secret_….json`, is reported as a note: it is in neither the
repository nor the app.

On the Mac that builds it, the released app counts as a different app from the
development build, because macOS ties permissions and Keychain items to the
signing certificate. Opening it there asks for Screen Recording and Calendar
again, and for the login password to read the saved keys.

## First run

Carpe opens a setup window with three steps:

1. **Calendar.** Choose *Apple Calendar* or *Google Calendar*. For Apple
   Calendar, click *Allow Calendar Access* and allow full access: Carpe lists
   your calendars, adds events, and deletes one when you choose Undo. If access
   was refused earlier, the button opens *System Settings > Privacy & Security >
   Calendars* instead. For Google Calendar, the button opens Settings.
2. **Screen Recording.** Click *Open Screen Recording Settings*, switch Carpe
   on, then click *Relaunch Carpe*. macOS applies the grant only to a fresh
   launch.
3. **Notifications.** Click *Allow Notifications*.

The same window is under *Permissions…* in the menu. A Mac where Google was
already set up before the choice existed stays on Google and isn't asked.

Then open *Settings…*:

1. Paste your Anthropic API key and click *Save Key*.
2. Under *Calendar*, check the service. Settings only shows the fields of the
   selected one.
   - **Apple Calendar:** pick the *Default calendar*. The list has the
     calendars that can be changed, so no subscriptions or birthdays. Until you
     pick one, it is the default calendar from the Calendar app's own settings.
   - **Google Calendar:** paste the Google **Client ID** and **Client secret**
     (from [Google Cloud setup](#google-cloud-setup)) and click *Connect
     Google*. Your browser opens Google's sign-in. Approve it with both boxes
     ticked, and the status changes to *Connected*. Then pick the *Default
     calendar*.
3. Switch on *Ask which calendar every time* if captures should not all go to
   the default. See [Choosing the calendar](#choosing-the-calendar).

### Connecting Google Calendar

The sign-in is OAuth 2.0 for desktop apps with PKCE. Carpe opens the system
browser and listens on `http://127.0.0.1` on a random port for Google's
redirect. The listener accepts connections from this Mac only and closes when
the sign-in ends or after five minutes. Two scopes are requested:

- `https://www.googleapis.com/auth/calendar.events` to create and delete events.
- `https://www.googleapis.com/auth/calendar.calendarlist.readonly` to read the
  list of your calendars for the *Default calendar* menu and the picker. Of the
  four scopes Google accepts for listing calendars, it is the narrowest: it
  can't read events and can't change anything.

A sign-in made before the second scope was added keeps working for events, but
can't list calendars: Settings then shows the old *Calendar ID* field and says
so. Click *Disconnect*, then *Connect Google*, to get the list. The same
happens if the calendar-list box is unticked on Google's consent screen.

Events go to the *Default calendar*, which starts as the account's main one. To
keep captured events apart, create a calendar in Google Calendar (for example
"Carpe") and pick it.

*Disconnect* removes the saved sign-in and asks Google to revoke it. If Google
stops accepting the sign-in, the menu shows *Reconnect Google…*.

## Using it

Press **Ctrl+Opt+Cmd+C** (or choose *Capture Event* from the menu), drag over
the event, and release. Esc cancels. The menu bar icon becomes a spinner while
Claude reads the image, and a notification shows the result. The icon also shows
a checkmark or a warning triangle for a few seconds afterwards, and the menu
keeps the last result, so the outcome is visible even when a Focus mode holds
the notification back.

### Choosing the calendar

With *Ask which calendar every time* off, every capture goes to the default
calendar. With it on, a small panel appears once Claude has read the
screenshot. It shows the event's title and time and your calendars with their
colours:

- **↑ ↓**, **1–9** or a click selects a calendar. **Return** or *Add* saves the
  event there. A double click does both.
- **Esc** or *Cancel* creates nothing.
- A screenshot with several events gets one panel, and the choice applies to
  all of them.

The calendar that starts out selected is Claude's suggestion. To make one,
Claude gets the names of your calendars along with the screenshot and returns
`suggested_calendar`, which is one of those names or nothing. Without a
suggestion, the calendar chosen last time is selected, and failing that the
default. Two calendars with the same title are shown with their account, as in
"Home (iCloud)". The panel doesn't bring Carpe to the front, so the app you
were in stays active behind it.

The calendar names are only sent to Claude while this setting is on.

### Open and Undo

The "Added" notification has two buttons. macOS shows them when you hover over
the banner and click *Options*, or directly if Carpe's notification style is
set to *Alerts* in System Settings.

- **Open** shows the event in the Calendar app, which moves to its date, or the
  event's page in Google Calendar. Clicking the notification itself does the
  same. A capture with several events opens the first.
- **Undo** deletes the event, or all events from that capture, and confirms with
  a "Removed" notification.

Both work from Notification Center later on, also after Carpe has been
restarted, and they act on the service the event was saved to even if another
one is selected by then. The menu has *Open Last Event* and *Undo Last Event* for the most
recent capture.

### Shortcut and launch at login

In *Settings…* under *General*, click the shortcut, then press the new
combination. It needs at least one of ⌃, ⌥ and ⌘. If another app already holds
the combination, Carpe says so and keeps the old one. *Reset* returns to
Ctrl+Opt+Cmd+C.

*Launch at login* registers the running copy of Carpe as a login item. Run
`make install` first and switch it on in the copy in `/Applications`; the copy
in `build/` is deleted by `make clean`. The installed copy has the same bundle
ID and signature, so it keeps the Screen Recording permission and the Keychain
items.

### How the capture is taken

Carpe runs `/usr/sbin/screencapture -i -x -c`, which puts the selection on the
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
defaults write com.koreneff.carpe captureToFile -bool YES
```

## Testing each stage

**Stage 1, capture only.** Before you save an API key, a capture ends with the
notification "Screenshot captured, but there's no API key" and the size of the
image, which confirms the hotkey and the capture. To inspect the file itself:

```sh
defaults write com.koreneff.carpe keepCaptures -bool YES   # keep the temp files
log stream --info --predicate 'subsystem == "com.koreneff.carpe"'
```

The log prints the path of each kept file. Turn it off again with
`defaults delete com.koreneff.carpe keepCaptures`.

**Stage 2, extraction.** After a capture, *Copy Last Result as JSON* in the menu
copies what Claude returned, and the `log stream` command above prints it. To
run an image file through the same code without the hotkey:

```sh
make extract IMG=~/Desktop/some-screenshot.png
```

This prints the JSON and the resolved dates. It reads the API key from the
Keychain, or from `ANTHROPIC_API_KEY` if the Keychain has none. Add calendar
names to see which one Claude would suggest:

```sh
make extract IMG=~/Desktop/some-screenshot.png CALENDARS="Work,Home,Kids football"
```

**Stage 3, Google Calendar.** Once *Settings* shows *Connected*, a capture ends
with the notification "Added: …" and the event is in the calendar. To check the unhappy paths: a wrong Calendar ID gives a
notification naming the ID, and removing Carpe's access at
<https://myaccount.google.com/connections> makes the menu offer
*Reconnect Google…* at the next capture, within an hour.

**Stage 3, Apple Calendar.** Select *Apple Calendar* in Settings and allow
access. A capture ends with "Added: …" and the event is in the calendar picked
in Settings. To check the unhappy path, switch Carpe off under *System
Settings > Privacy & Security > Calendars* and capture again: the notification says access is missing, the setup window
opens, and the menu shows *Allow Calendar Access…*. To see the first-run
question again, run `tccutil reset Calendar com.koreneff.carpe` and
`defaults delete com.koreneff.carpe calendarService`.

**Stage 3, the calendar picker.** Switch on *Ask which calendar every time* and
capture. Check that the suggested calendar is selected, pick another with a
number key and press Return: the notification names the calendar. Capture again
and check that, when Claude suggests nothing, the calendar from last time is
selected. Capture once more and press Esc: nothing is added, and the menu says
"Not added: …".

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
- If a model rejects the structured request, Carpe asks for plain JSON
  instead, validates it, and retries once if it does not parse.
- With *Ask which calendar every time* on, the prompt also lists the calendar
  names, and the schema gets `suggested_calendar`: an enum of exactly those
  names, or null. A suggestion that is not one of the names is dropped.

The schema:

```
{ events: [ { title, start, end?, all_day, year_given, location?, description? } ],
  reason_if_none?,
  suggested_calendar? }   // only when calendar names were sent
```

`year_given` is an addition to the original spec. It is false when the
screenshot showed no year. `EventDateResolver` uses it to move a date that
landed in the past to its next occurrence, so that rule holds even if the model
gets the year wrong. The same file applies the one-hour default and converts
all-day ranges to the exclusive end date calendars expect. Its tests are in
`CarpeTests/EventDateResolverTests.swift`.

## Secrets

Four items are stored in the login Keychain under the service
`com.koreneff.carpe`: the Anthropic API key, the Google client ID, the Google
client secret, and the Google refresh token. The Google access token is kept in
memory only and fetched again after a relaunch. Apple Calendar needs no secret:
access is a macOS permission. The model ID, calendar service, calendar IDs,
shortcut and other plain settings are in UserDefaults. A notification carries
the IDs and link of the events it announced, so that Undo and Open work later. Nothing secret is in the repository
or the app; `make check-secrets` verifies that, and a release doesn't build without it passing.

## Project layout

```
project.yml            XcodeGen project definition, signing settings,
                       version, calendar usage text
scripts/release.sh     Signed, notarized disk image for other Macs
scripts/check-secrets.sh
                       Looks for credentials in files, history and a bundle
INSTALL.md             Installation guide for the person receiving the app
Carpe/Carpe.entitlements
                       Calendar access under the hardened runtime
Carpe/Core/            Logic with no UI: Claude client, prompt and schema,
                       date resolution, image scaling, region capture, the
                       CalendarService protocol with its Apple (EventKit) and
                       Google (sign-in and Calendar API) implementations
Carpe/App/             Menu bar item, hotkey and recorder, pipeline, calendar
                       picker panel, notifications, login item, settings and
                       permissions windows, --extract command
CarpeTests/            Unit tests; compiles Carpe/Core directly
```

## Google Cloud setup

You end up with a client ID and a client secret for a desktop OAuth client,
which go into Carpe's Settings. Google renames these console pages from time to time;
the names below are from its current guides.

1. Go to <https://console.cloud.google.com>, and create a project (for example
   "Carpe").
2. Enable the calendar API: *APIs & Services > Library*, search for
   **Google Calendar API**, click **Enable**.
3. Configure the consent screen: *Menu > Google Auth platform > Branding*, click
   **Get Started**.
   - App name and support email: anything, for example "Carpe" and your address.
   - Audience: **External**. (Internal exists only for Google Workspace
     organisations.)
   - Contact email, agree to the data policy, **Create**.
4. Add the scopes: *Data Access > Add or Remove Scopes*, add
   `https://www.googleapis.com/auth/calendar.events` and
   `https://www.googleapis.com/auth/calendar.calendarlist.readonly`, **Save**.
   These are the two scopes Carpe requests. If a scope isn't in the table,
   paste it under *Manually add scopes*.
5. Add yourself as a tester: *Audience > Test users > Add users*, enter the
   Google account whose calendar you want to use.
6. Create the client: *Google Auth platform > Clients > Create Client*,
   application type **Desktop app**, any name, **Create**. Copy the client ID
   and the client secret straight away, or download the JSON.

One thing to decide in step 5: while the app's publishing status is *Testing*,
Google expires refresh tokens after 7 days, so Carpe would ask you to
reconnect every week. Publishing the app (*Audience > Publish app*) removes that
limit. For a personal app you do not need to go through verification; Google
shows an "unverified app" warning once when you connect, which you can click
through.

Desktop clients may redirect to `http://127.0.0.1` on any port without
registering a redirect URI, which is what Carpe's sign-in uses.

## Troubleshooting

- **The screenshot only shows the desktop picture.** Screen Recording is not
  granted, or Carpe was not relaunched after granting it.
- **Nothing happens for about a minute after selecting.** Only in
  `captureToFile` mode, when Spotlight is slow. Delete that setting
  (`defaults delete com.koreneff.carpe captureToFile`) or fix Spotlight.
- **The shortcut does nothing.** Another app owns the combination. The menu
  says so when registration failed. Record a different one in Settings.
- **No Open or Undo buttons.** Hover over the banner and click *Options*, or use
  *Open Last Event* and *Undo Last Event* in the menu.
- **Launch at login stopped working.** The login item points at a copy of the
  app that has moved or been deleted. Switch it off and on in the copy you use.
- **No notification appears.** A Focus mode silences Carpe unless you add it
  under *System Settings > Focus > (your Focus) > Allowed Apps*. Silenced
  notifications still land in Notification Center. Also check
  *System Settings > Notifications > Carpe*.
- **"Carpe doesn't have access to your calendars".** Apple Calendar is
  selected and the permission is off. Use the button in the setup window
  (*Permissions…*) or in Settings; it opens *System Settings > Privacy &
  Security > Calendars*. If Carpe is listed there as *Add Only*, change it to
  *Full Access*.
- **A calendar is missing from the Apple Calendar list.** Only calendars that
  can be changed are listed. Subscribed, birthday and read-only shared
  calendars are left out.
- **Google says "Access blocked" when connecting.** The app is in *Testing* and
  the account is not listed under *Audience > Test users* (step 5).
- **"Google rejected the client ID or client secret".** One of the two was
  pasted wrong, or the client is not of the type *Desktop app*.
- **"Google Calendar API has not been used in project…".** The API is not
  enabled in the Cloud project (step 2).
- **"This Google sign-in doesn't let Carpe see your list of calendars".** The
  sign-in is from before Carpe asked for the calendar list, or that box was
  unticked on Google's consent screen. In Settings, click *Disconnect* and then
  *Connect Google*, and leave both boxes ticked.
- **The calendar panel doesn't react to the keyboard.** Another window took the
  keyboard. Click the panel once.
- **"Google has no calendar with the ID…".** The Calendar ID in Settings is not
  one this account can write to.
- **The menu shows *Reconnect Google…*.** Google stopped accepting the saved
  sign-in: access was removed, or the app is in *Testing* and seven days passed.
- **Checking what happened.** Key steps are logged:
  `log show --last 10m --predicate 'subsystem == "com.koreneff.carpe"'`
