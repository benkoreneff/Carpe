# Carpe

Carpe is a macOS menu bar app. Press a shortcut, drag-select part of the
screen, and the event in the screenshot is added to Apple Calendar or Google
Calendar. It works on anything that shows a date: an email, a chat message, a
web page, a poster.

## Requirements

- macOS 14 (Sonoma) or later
- A Mac with Apple silicon or Intel
- An Anthropic API key. Carpe uses Claude to read the screenshot, and each
  capture is one small request billed to your key. Create a key at
  <https://console.anthropic.com>. The Anthropic API is prepaid, so a new
  account needs credit added before the key works.

## Install

1. Download
   [Carpe.dmg](https://github.com/benkoreneff/Carpe/releases/latest/download/Carpe.dmg).
2. Open it.
3. Double-click Carpe in the window that opens. macOS asks whether you want to
   open an app downloaded from the internet. Click **Open**.
4. Carpe asks **Move Carpe to Applications?** Click **Move**.

Carpe has no Dock icon and no main window. It is the small icon of a sun rising
over a horizon in the menu bar. You can now eject the Carpe disk in Finder and
delete the `.dmg` file.

## First run

A setup window opens with three steps. It is also under **Permissions…** in
Carpe's menu.

1. **Calendar.** Choose **Apple Calendar** and click **Allow Calendar Access**,
   then **Allow Full Access** when macOS asks. Carpe uses the permission to
   list your calendars, add events, and delete an event when you choose Undo.
   To use Google Calendar instead, see
   [Google Calendar setup](#google-calendar-setup).
2. **Screen Recording.** Click **Open Screen Recording Settings**, switch Carpe
   on, then click **Relaunch Carpe**. Without this permission a screenshot
   shows only your desktop picture, not your windows.
3. **Notifications.** Click **Allow Notifications**. Carpe uses a notification
   to tell you what it added or what went wrong.

Then choose **Settings…** from the menu:

1. Paste your key into **Anthropic API key** and click **Save Key**. It is
   stored in your Mac's Keychain.
2. Under **Calendar**, check that **Calendar service** is the one you want, and
   pick the **Default calendar** for new events. Switch on **Ask which calendar
   every time** if you would rather choose for each event.
3. Under **General**, switch on **Launch at login** if you want Carpe to start
   with your Mac. The shortcut can be changed here too.

To capture an event, press **⌃⌥⌘C** (Control, Option, Command and C). Drag a
box around the event and let go, or press Esc to cancel. A few seconds later a
notification says **Added: …** and the event is in your calendar. Hold the
pointer over the notification and click **Options** to **Open** the event or
**Undo** it. The same two commands are in the menu.

## Google Calendar setup

The recommended way is to add your Google account to your Mac and keep Carpe
on Apple Calendar. Carpe then saves to your Google calendars through the
Calendar app, and nothing has to be set up at Google.

1. Open **System Settings** and click **Internet Accounts** in the sidebar.
2. Click **Add Account…**, choose **Google**, and sign in.
3. Leave **Calendars** switched on for the account.
4. In Carpe, choose **Apple Calendar** as the calendar service. Your Google
   calendars are now in the **Default calendar** list in **Settings…**.

To have Carpe talk to Google directly instead, it needs a Google **client ID**
and **client secret**. None is built into the app. There are two ways to get
them:

- Ask whoever shared Carpe with you. If their Google Cloud project is still in
  *Testing*, they also have to add your Google address as a test user, or
  Google answers "Access blocked" when you sign in.
- Create your own desktop OAuth client in Google Cloud. It is free and takes
  about ten minutes. The steps are in
  [DEVELOPMENT.md](DEVELOPMENT.md#google-cloud-setup).

Then:

1. Open **Settings…** and set **Calendar service** to **Google Calendar**.
2. Paste the **Client ID** and the **Client secret**.
3. Click **Connect Google**. Your browser opens Google's sign-in. When Google
   says it hasn't verified this app, click **Advanced**, then **Go to Carpe
   (unsafe)**. The name is the one the Google Cloud project gave the app. Leave
   both permission boxes ticked.
4. Back in Settings, the status reads *Connected*. Pick the **Default
   calendar**.

If the menu later shows **Reconnect Google…**, Google has stopped accepting the
sign-in. Choose it and sign in again. With a Google Cloud project that is still
in *Testing*, this happens every seven days.

## Updating

Download the new
[Carpe.dmg](https://github.com/benkoreneff/Carpe/releases/latest/download/Carpe.dmg),
open it, double-click Carpe, and click **Move**. This quits the copy that is
running and replaces the one in Applications. Your settings, API key and
permissions stay as they are. The version you have is the grey line above
*Quit Carpe* in the menu.

To remove Carpe, choose **Quit Carpe** from the menu and drag it from
Applications to the Trash.

## Troubleshooting

- **macOS says Carpe "can't be opened" or "is damaged".** Drag Carpe from the
  disk image window onto the Applications shortcut next to it, then run this
  in Terminal and open Carpe again:

  ```sh
  xattr -dr com.apple.quarantine /Applications/Carpe.app
  ```

- **The screenshot only shows the desktop picture.** Screen Recording is off,
  or Carpe wasn't relaunched after you switched it on. Choose **Permissions…**
  from the menu and do that step again.
- **"Carpe doesn't have access to your calendars".** Choose **Permissions…**
  and click the button under *Calendar*. If Carpe is listed in System Settings
  as *Add Only*, change it to **Full Access**.
- **Nothing happens when you press the shortcut.** Another app uses the same
  one. The menu says so. Open **Settings…**, click the shortcut and press a
  different combination.
- **No notification appears.** A Focus mode such as Do Not Disturb is holding
  it back. The menu bar icon shows a tick or a warning triangle for a few
  seconds instead, and the menu shows the last result.
- **The API key was rejected.** Paste it again in **Settings…** and check that
  nothing is missing from the start or the end.

More cases, including the Google error messages, are in
[DEVELOPMENT.md](DEVELOPMENT.md#troubleshooting).

## Privacy

Carpe runs on your Mac and there is no Carpe server. When you capture, the part
of the screen you selected is sent from your Mac straight to the Anthropic API,
with your own API key, along with the current date, time and time zone. If *Ask
which calendar every time* is on, the names of your calendars are sent as well,
so that Claude can suggest one. Carpe deletes its temporary copy of the
screenshot when the capture has been processed.

Events are saved to Apple Calendar through macOS, or sent from your Mac
straight to Google. The API key and the Google credentials are kept in your
Keychain.

The full policy is at <https://benkoreneff.github.io/carpe-site/privacy.html>.

## Installing with an AI assistant

An assistant with shell access, such as Claude Code, can do the download and
the copy. This script installs or updates Carpe. Run it as one script, not line
by line: it stops at the first step that fails, and it leaves the installed
copy alone unless the downloaded one is notarized by Apple.

```sh
set -e
curl -fL -o /tmp/Carpe.dmg https://github.com/benkoreneff/Carpe/releases/latest/download/Carpe.dmg
MOUNT=$(mktemp -d)
hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT" /tmp/Carpe.dmg
trap 'hdiutil detach "$MOUNT"; rm -f /tmp/Carpe.dmg' EXIT
if ! spctl -a -vv "$MOUNT/Carpe.app" 2>&1 | grep -q "source=Notarized Developer ID"; then
    echo "Carpe.app is not notarized by Apple. Nothing was installed." >&2
    exit 1
fi
pkill -x Carpe || true
rm -rf /Applications/Carpe.app
ditto "$MOUNT/Carpe.app" /Applications/Carpe.app
open /Applications/Carpe.app
```

The assistant can't do the rest, and shouldn't try. You have to:

- grant Calendar, Screen Recording and Notifications yourself in the setup
  window, because macOS only accepts these from the person at the Mac;
- paste your Anthropic API key into **Settings…** yourself. Don't give the key
  to the assistant.

## Building from source

[DEVELOPMENT.md](DEVELOPMENT.md) covers building, signing and releasing, how
the extraction works, and the Google Cloud setup.
