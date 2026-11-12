# Installing Carpe

Carpe sits in the menu bar. You press a shortcut, drag a box around an event
on your screen (an email, a chat message, a poster), and the event is added to
your calendar.

You need a Mac with macOS 14 (Sonoma) or later. To check, choose
*Apple menu > About This Mac*.

## 1. Install

1. Double-click `Carpe-<version>.dmg`.
2. In the window that opens, drag **Carpe** onto **Applications**.
3. Open **Carpe** from your Applications folder. The first time, macOS asks
   whether you want to open an app downloaded from the internet. Click
   **Open**.

If you opened Carpe straight from the disk image window without dragging it
first, it asks **Move Carpe to Applications?** Click **Move** and it does the
same thing for you.

A small icon of a sun rising over a curved horizon appears in the menu bar at
the top right of the screen, and a window called *Welcome to Carpe* opens.
Carpe has no Dock icon and no main window. Everything is behind that menu bar
icon.

You can now eject the Carpe disk in Finder and delete the `.dmg` file.

## 2. Go through the welcome window

It has three steps. Each one gets a green tick when it is done.

**Calendar**

1. Choose **Apple Calendar**.
2. Click **Allow Calendar Access**.
3. macOS asks for permission. Click **Allow Full Access**. Carpe needs this
   to show your calendars, add events, and remove one when you click Undo.

**Screen Recording**

1. Click **Open Screen Recording Settings**.
2. In the list, switch **Carpe** on. Your Mac may ask for your password or
   Touch ID.
3. If macOS offers **Quit & Reopen**, click it. Otherwise go back to the
   welcome window and click **Relaunch Carpe**.

Without this, Carpe can only see your desktop picture instead of your
windows.

**Notifications**

1. Click **Allow Notifications**.
2. macOS shows a notification asking for permission. Click **Allow**.

Carpe tells you what it added, or what went wrong, with a notification.

If you closed the window too early, click the menu bar icon and choose
**Permissions…** to get it back.

## 3. Paste the API key

Carpe uses Claude, an AI service from Anthropic, to read the screenshot. That
needs an API key: a long piece of text that starts with `sk-ant-`. Benjamin
will send you a key; paste it into Settings → Anthropic API key:

1. Click the menu bar icon and choose **Settings…**.
2. Paste the key into **Anthropic API key**.
3. Click **Save Key**. It should say *Saved in the Keychain*.

While you are in Settings:

- **Default calendar** is where new events go.
- **Ask which calendar every time** lets you pick the calendar for each event
  instead.
- **Launch at login** starts Carpe whenever you start your Mac.

## 4. Use it

1. Press **Control + Option + Command + C** (⌃⌥⌘C). The pointer becomes a
   crosshair.
2. Drag a box around the event and let go. Press **Esc** to cancel.
3. After a few seconds a notification says **Added: …** and the event is in
   your calendar.

Hold the pointer over the notification and click **Options** to **Open** the
event in Calendar or **Undo** it. The same two commands are under the menu bar
icon as *Open Last Event* and *Undo Last Event*.

## If something doesn't work

- **The screenshot only shows my desktop picture.** Screen Recording isn't on,
  or Carpe wasn't relaunched after you switched it on. Choose
  **Permissions…** from the menu and do that step again.
- **It says Carpe doesn't have access to my calendars.** Choose
  **Permissions…** from the menu and click the button under *Calendar*. In the
  list that opens, set Carpe to **Full Access**.
- **Nothing happens when I press the shortcut.** Another app may use the same
  shortcut. Open **Settings…**, click the shortcut, and press a different
  combination.
- **I don't see a notification.** A Focus mode such as Do Not Disturb hides
  it. The menu bar icon briefly shows a tick or a warning triangle instead, and
  the menu shows the last result.
- **It says the API key was rejected.** Paste it again in **Settings…** and
  check that nothing is missing from the start or the end.

When asking for help, mention the version. It is the grey line just above
*Quit Carpe* in the menu, for example *Carpe 0.1.2*.

## Removing Carpe

Choose **Quit Carpe** from the menu, then drag Carpe from Applications to
the Trash.
