# Developing Carpe

Building, signing and releasing Carpe, how it works inside, and how to create
the Google OAuth client. Installing and using the app is in
[README.md](README.md).

## Requirements

- macOS 14 or later
- Xcode (the full app, not only the Command Line Tools)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- A Developer ID Application signing certificate. Check with
  `security find-identity -v -p codesigning`.

## Build and run

```sh
make run      # generate the project, build, verify the signature, launch
make test     # unit tests
make build    # build only
make install  # optimised build into /Applications, then launch it
make release  # notarized Carpe-<version>.dmg for other Macs, see below
make check-secrets  # look for credentials in the files and the git history
make clean    # remove build output, the generated project, and dist.noindex/
```

`make clean` deletes the release images in `dist.noindex/` too. Copy a disk
image you still need somewhere else first.

The Makefile calls `xcodegen` and `xcodebuild`. If `xcode-select` points at the
Command Line Tools, it uses `/Applications/Xcode.app` for these commands and
leaves the system setting alone. The built app is
`build.noindex/Build/Products/Debug/Carpe.app`.

Build output goes to `build.noindex/` and release images to `dist.noindex/`.
Spotlight skips folders whose names end in `.noindex`, so the copies of
`Carpe.app` in there don't appear in Spotlight or Launchpad searches next to the
one in `/Applications`.

`Carpe.xcodeproj` is generated from `project.yml` and is not checked in. To
work in Xcode, run `make gen` and open it.

To run an image file through the extraction without the hotkey:

```sh
make extract IMG=~/Desktop/some-screenshot.png
make extract IMG=~/Desktop/some-screenshot.png CALENDARS="Work,Home,Kids football"
```

This prints the JSON and the resolved dates, and with `CALENDARS` the calendar
Claude would suggest. It reads the API key from the Keychain, or from
`ANTHROPIC_API_KEY` if the Keychain has none.

### Signing

Every build is signed with the `Developer ID Application` certificate of team
`375L8HDHKR`, and the bundle ID is fixed at `com.koreneff.carpe`. Both are set
in `project.yml`. macOS ties the Screen Recording and Calendar grants and the
Keychain items to that pair, so an ad-hoc signature or a new bundle ID would
make it ask again after every build. `make build` fails if the result is not
signed this way. To build with your own certificate, change `DEVELOPMENT_TEAM`
in `project.yml` to your team.

Development builds use the same certificate as the released app on purpose.
Signed with an Apple Development certificate, the copy in the build folder and
the copy in `/Applications` were two different apps to macOS that shared one
bundle ID: only one of them could hold the Screen Recording grant, and the
other asked for the login password for each saved key.

## Releasing to other Macs

`scripts/release.sh` (or `make release`) produces
`dist.noindex/Carpe-<version>.dmg`, which Gatekeeper accepts on any Mac with
macOS 14 or later. The first launch still shows the usual question about an app
downloaded from the internet.

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
   secure timestamp. Unlike a development build, it is not debuggable (no
   `get-task-allow`).
4. Checks the result: signature, hardened runtime, timestamp, the calendar
   entitlement, no `get-task-allow`, both architectures. The binary is
   stripped, and the script fails if any file in the bundle still contains a
   `/Users/` path or the user name of the Mac that built it.
5. Runs the secret check again on the app bundle, the executable included.
6. Has Apple notarize the app and staples the ticket to it, so the app also
   opens on a Mac that is offline.
7. Packs the app and an Applications shortcut into the disk image, signs it,
   has Apple notarize that too, staples it, and asks Gatekeeper for its verdict
   on both.

`scripts/release.sh --skip-notarization` does everything except Apple's part
and names the image `-unnotarized`, to try the build. Other Macs refuse to open
that one.

Opening the release build straight from `build.noindex/` makes it ask to move
itself to Applications, like any release copy outside that folder.

The version is `MARKETING_VERSION` in `project.yml`. It is in the disk image's
name and in Carpe's menu, on the grey line above *Quit Carpe*.

`scripts/check-secrets.sh` also runs by itself (`make check-secrets`). It
prints only the first characters of a match. A file that git ignores, such as a
downloaded `client_secret_….json`, is reported as a note: it is in neither the
repository nor the app. No such file belongs in this folder.

On the Mac that builds it, the released app and the development build count as
the same app, because they share the bundle ID and the signing certificate.
They use the same permissions, Keychain items and settings.

## How it works

### The capture

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

The menu bar icon becomes a spinner while Claude reads the image. Afterwards it
shows a checkmark or a warning triangle for a few seconds, and the menu keeps
the last result, so the outcome is visible even when a Focus mode holds the
notification back.

### The extraction

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

`year_given` is false when the screenshot showed no year. `EventDateResolver`
uses it to move a date that landed in the past to its next occurrence, so that
rule holds even if the model gets the year wrong. The same file applies the
one-hour default and converts all-day ranges to the exclusive end date
calendars expect. Its tests are in `CarpeTests/EventDateResolverTests.swift`.

After a capture, *Copy Last Result as JSON* in the menu copies what Claude
returned. To keep the screenshots and watch the log:

```sh
defaults write com.koreneff.carpe keepCaptures -bool YES   # keep the temp files
log stream --info --predicate 'subsystem == "com.koreneff.carpe"'
```

The log prints the path of each kept file. Turn it off again with
`defaults delete com.koreneff.carpe keepCaptures`.

### Calendar services

Events are saved to one calendar service, chosen at first run and under
*Settings… > Calendar service*:

- **Apple Calendar** saves through the Calendar app (EventKit), so it reaches
  every account set up there. It needs the Calendars permission and nothing
  else.
- **Google Calendar** talks to Google directly and needs an OAuth client (see
  [Google Cloud setup](#google-cloud-setup)). Until Google is connected, a
  capture ends in a preview: the notification shows what would be added, titled
  "Preview, not saved".

The Apple Calendar list has the calendars that can be changed, so no
subscriptions or birthdays. Until one is picked, events go to the default
calendar from the Calendar app's own settings. To see the first-run question
again, run `tccutil reset Calendar com.koreneff.carpe` and
`defaults delete com.koreneff.carpe calendarService`.

### The Google sign-in

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

### One copy, in Applications

Only one copy of Carpe runs at a time. A second one, started while the first is
running, activates the first and quits straight away, before it registers the
shortcut or adds a menu bar icon.

A release build that is opened from anywhere other than `/Applications` (the
disk image, Downloads, the build folder) asks *Move Carpe to Applications?*

- **Move** quits any Carpe that is running, copies this one to `/Applications`
  (replacing a copy that is there; the question names its version), moves the
  copy you opened to the Trash, and reopens Carpe from Applications.
- **Not now** changes nothing. The question comes back at the next launch.

The opened copy is not moved to the Trash when it is in a read-only disk image,
or when macOS is running a downloaded app from a randomised path (Gatekeeper's
app translocation), because the real copy can't be located from there. If
copying fails, for example without permission to change `/Applications`, Carpe
says so and carries on from where it is.

The question is asked before the one-copy check, so a newer version opened from
its disk image can replace an older one that is running. Development (Debug)
builds never ask.

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
one is selected by then. The menu has *Open Last Event* and *Undo Last Event*
for the most recent capture.

### Shortcut and launch at login

In *Settings…* under *General*, click the shortcut, then press the new
combination. It needs at least one of ⌃, ⌥ and ⌘. If another app already holds
the combination, Carpe says so and keeps the old one. *Reset* returns to
Ctrl+Opt+Cmd+C.

*Launch at login* registers the running copy of Carpe as a login item. When
developing, run `make install` first and switch it on in the copy in
`/Applications`; the copy in `build.noindex/` is deleted by `make clean`. The
installed copy has the same bundle ID and signature, so it keeps the Screen
Recording permission and the Keychain items.

## Secrets

Four items are stored in the login Keychain under the service
`com.koreneff.carpe`: the Anthropic API key, the Google client ID, the Google
client secret, and the Google refresh token. The Google access token is kept in
memory only and fetched again after a relaunch. Apple Calendar needs no secret:
access is a macOS permission. The model ID, calendar service, calendar IDs,
shortcut and other plain settings are in UserDefaults. A notification carries
the IDs and link of the events it announced, so that Undo and Open work later.
Nothing secret is in the repository or the app; `make check-secrets` verifies
that, and a release doesn't build without it passing.

## Project layout

```
project.yml            XcodeGen project definition, signing settings,
                       version, calendar usage text
scripts/release.sh     Signed, notarized disk image for other Macs
scripts/check-secrets.sh
                       Looks for credentials in files, history and a bundle
scripts/make-icons.py  Draws the app icon and the menu bar glyph (needs Pillow)
design/carpe-icon.svg  Vector master of the app icon
README.md              What Carpe is, installing and using it
DEVELOPMENT.md         This file
Carpe/Carpe.entitlements
                       Calendar access under the hardened runtime
Carpe/Assets.xcassets/ App icon (AppIcon) and menu bar glyph (MenuBarIcon)
Carpe/Core/            Logic with no UI: Claude client, prompt and schema,
                       date resolution, image scaling, region capture, the
                       CalendarService protocol with its Apple (EventKit) and
                       Google (sign-in and Calendar API) implementations
Carpe/App/             Launch checks (one copy, move to Applications), menu
                       bar item, hotkey and recorder, pipeline, calendar
                       picker panel, notifications, login item, settings and
                       permissions windows, --extract command
CarpeTests/            Unit tests; compiles Carpe/Core directly
```

## Google Cloud setup

You end up with a client ID and a client secret for a desktop OAuth client,
which go into Carpe's Settings. Google renames these console pages from time to
time; the names below are from its current guides.

1. Go to <https://console.cloud.google.com>, and create a project (for example
   "Carpe").
2. Enable the calendar API: *APIs & Services > Library*, search for
   **Google Calendar API**, click **Enable**.
3. Configure the consent screen: *Menu > Google Auth platform > Branding*, click
   **Get Started**.
   - App name and support email: anything, for example "Carpe" and your address.
   - If you fill in the home page and privacy policy links, Carpe's are
     <https://benkoreneff.github.io/carpe-site/> and
     <https://benkoreneff.github.io/carpe-site/privacy.html> (repository
     `benkoreneff/carpe-site`).
   - Audience: **External**. (Internal exists only for Google Workspace
     organisations.)
   - Contact email, agree to the data policy, **Create**.
4. Add the scopes: *Data Access > Add or Remove Scopes*, add
   `https://www.googleapis.com/auth/calendar.events` and
   `https://www.googleapis.com/auth/calendar.calendarlist.readonly`, **Save**.
   These are the two scopes Carpe requests. If a scope isn't in the table,
   paste it under *Manually add scopes*.
5. Add yourself as a tester: *Audience > Test users > Add users*, enter the
   Google account whose calendar you want to use. While the project is in
   *Testing*, also add the address of anyone else you give the client ID and
   secret to.
6. Create the client: *Google Auth platform > Clients > Create Client*,
   application type **Desktop app**, any name, **Create**. Copy the client ID
   and the client secret straight away, or download the JSON.

Keep the downloaded `client_secret_….json` outside the project folder. Nothing
in the code or the scripts reads it: it is only a backup of the two values,
which Carpe takes from the fields in Settings and stores in the Keychain.
`.gitignore` still excludes `client_secret*.json` in case one is ever saved
into the project folder.

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
