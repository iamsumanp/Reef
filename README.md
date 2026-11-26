# Reef

The macOS window manager that gives every app its own Alt-Tab. 

![Cover photo. Reef logo and UI.](./github-assets/reef-banner-1280-short.jpg)

[Download for macOS](https://getreef.app) · [GitHub Releases](https://github.com/gouwsxander/Reef/releases/latest) (Requires macOS 14.6+)

[How we made Reef (YouTube)](https://youtu.be/niRCi5zJvHU)

> **About this fork:** adds window previews to the switcher, a switcher for apps without a
> number, windows in every space (including full-screen apps), and a prompt before opening apps
> that aren't running. See [Fork additions](#fork-additions).

## Key Features

Reef lets you bind applications to number keys and cycle through their windows with an Alt-Tab-like interface.

We built Reef because we wanted a fast and simple window switcher for macOS.

- Bind applications to number keys to refocus to **any** window for that app
- Assign profiles for different sets of bindings
- Do your binding and profile management through the keyboard
- Customizable keyboard shortcuts


## Usage

### Binding
You should start by binding different applications to the number keys. You can do this:
- through **Preferences → Profiles** (accessed through the menu bar), or
- by selecting the application of your choice and then pressing <kbd>Ctrl</kbd> + <kbd>Option</kbd> + <kbd>Shift</kbd>.

### Profiles
You can also set your bindings up in different profiles.

For example, you may want two profiles:
- "Coding": Which binds your favourite editor, browser, and terminal
- "Browsing": Which binds your favourite web browser, messaging app, and music client

You can switch between profiles:
- using the menu bar, or
- by binding them to the number keys, and then pressing <kbd>Ctrl</kbd> + <kbd>Option</kbd> + <kbd>[0-9]</kbd>.

### Switching applications
Suppose you're in your coding profile, and have your editor bound to `0`.

To switch between apps and windows:
1. Hold <kbd>Control</kbd> and press <kbd>0</kbd> to open a panel showing each of your editor's windows.
2. Press <kbd>0</kbd> multiple times to select the specific window you want.
3. Release <kbd>Control</kbd> to switch to the selected window.

In this way, Reef gives every app its own 'Alt-Tab'.

Note that window switching is scoped to your current [macOS space](https://support.apple.com/en-ca/guide/mac-help/mh14112/mac).
(This fork lists windows in every space; see [Fork additions](#fork-additions).)

### Customization

You can customize the modifiers for switching applications and profiles, and for binding different applications in **Reef Preferences → Shortcuts**.

Reef also pairs well with [Rectangle](https://github.com/rxhanson/Rectangle):
- Rectangle positions & re-arranges your windows
- Reef re-focuses your windows


## Installation

Download the latest release on [our website](https://getreef.app) or [GitHub](https://github.com/gouwsxander/Reef/releases/latest)

Simply: 
1) Download the `.zip` and unzip the file.
2) Drag `Reef.app` into your Applications folder.

Reef is free/pay-what-you-want. Use the link on our website to support us.

### Compatibility

Reef is compatible with **macOS 14.6 (Sonoma)** and onwards. 

You can find your macOS version from the ** → About This Mac** page.


## Development

Please share issues and feedback via the [GitHub issues page](https://github.com/gouwsxander/Reef/issues).

Feel free to submit pull requests, though we can't guarantee that we'll get to them.


## Fork additions

- **Window previews.** Each window in the switcher shows a live picture of itself. Four layouts
  are available under **Preferences → General → Switcher style**: grid of cards (default),
  list + big preview, list with large pictures, and big preview + strip.
- **A second line per window.** Browsers show the website (`claude.ai`), Finder shows the folder
  (`~/Desktop/project`), document apps show the file's folder; "Minimized" or the monitor name
  appear when they help tell windows apart.
- **Full titles.** The part every window of an app shares (such as a browser profile name) is
  left out, long titles wrap to two lines, and Dia's shortened window titles are replaced with
  the full page title from its address bar.
- **Centred on your screen.** The switcher opens in the middle of the screen the mouse is on.
- **Windows in every space.** Windows on other desktops, in full-screen apps, minimized or on
  another display (including Sidecar) are listed too, labelled "Other desktop", "Full screen" or
  "Minimized", and switching to one moves you to its space. Switching works from inside a
  full-screen app as well.
- **Tap to switch, hold to choose.** A quick <kbd>modifier</kbd> + number goes straight to the
  app's last window without the switcher ever appearing. Keep holding the modifier, or press the
  number twice, and the switcher with every window shows up, still on that last window; each
  press after that moves to the next one. Already in that app, a single press shows the switcher
  at once, starting on the window you're in. Works the same for
  <kbd>modifier</kbd> + <kbd>`</kbd>. Set the hold under **Preferences → General → Show the
  switcher** ("Right away" brings back the old behaviour).
- **Which screen.** When an app's windows are spread over several screens, each card is tagged
  with its screen by name (Mac, iPad for Sidecar, or the monitor's maker, such as BenQ); the one
  you're working on reads "BenQ · here" and stands out, and cards on other screens are dimmed. If a tap would take you to another screen while the app also has a window
  on yours, the switcher opens instead, starting on the window here.
- **Mouse in the switcher.** While it's open, moving the pointer over a card selects it (letting
  go of the modifier then switches there) and clicking a card switches at once. A switcher that
  opens under a resting pointer keeps the keyboard's choice until the pointer actually moves.
- **No slide between spaces.** Switching to a window in another desktop or full-screen app
  jumps there instantly instead of playing the macOS slide (Reduce motion only turns it into a
  fade). Reef posts the Dock a synthetic swipe too fast to animate, the technique from
  [InstantSpaceSwitcher](https://github.com/jurplel/InstantSpaceSwitcher) (MIT), so no SIP
  change is needed. It applies to spaces on the display under the pointer; turn it off with
  `defaults write io.github.iamsumanp.reef instantSpaceSwitch -bool false`.
- **Apps without a number: <kbd>modifier</kbd> + <kbd>`</kbd>.** Opens the same card grid with
  the windows of every running app that has no number, frontmost first. Keep pressing
  <kbd>`</kbd> or use the arrow keys to move, or type to filter by app or window name (then
  <kbd>Return</kbd> switches). Pressing <kbd>modifier</kbd> + a free number while it's open gives
  the selected app that number. Apps with no window anywhere (running in the background after
  their last window closed) are left out, as in Mission Control. Turn it off under
  **Preferences → General**.
- **Confirm before opening an app.** Pressing the number of an app that isn't running shows
  "*App* isn't open — press the number again to open it"; letting go of the modifier or
  pressing <kbd>Esc</kbd> cancels. **Preferences → General → When the app isn't running** can
  also open it right away, or do nothing at all (no prompt, no launch).
- **Only real windows.** Picture-in-picture videos (such as a browser's YouTube popup), palettes,
  windows that draw nothing at all (such as Claude's transparent screen overlay) and other
  windows that float above normal ones are left out, so they don't count as a second
  window or stop the number key from switching straight to the app.
- **Reaches frozen apps too.** An app that has stopped responding can't bring its own window
  forward, and macOS lets no other app do it. Reef switches to the window's space and hides the
  apps covering it (as Hide Others would) so it's in view; they come back when you switch to
  them. After the first try Reef stops waiting a full second on that app.
- **Reliable after long idle.** Letting go of the modifier before a slow app answered used to
  leave the panel waiting; Reef now switches right away. An app that doesn't answer is given up
  on after 1 second and its windows come from the window server instead, and Reef opts out of
  App Nap.

Previews need **Screen Recording** (System Settings → Privacy & Security → Screen & System Audio
Recording). Without it, the switcher keeps the original text-only look, with the second line.
Window names in other spaces need it too.

### Building without Xcode

`./build.sh` builds, signs and installs `~/Applications/Reef.app` with only the Command Line
Tools (`Package.swift` mirrors the Xcode target). It uses its own bundle id and no update feed, so
it can sit next to the official app. Put a signing identity in a gitignored `build.local.sh`
(`REEF_SIGN_KEYCHAIN`, `REEF_SIGN_PASSWORD`, `REEF_SIGN_NAME`) to keep permissions across rebuilds.

With `REEF_DEBUG=1`, the build logs every switch (key press, window lookup, focus, picture
timing) to `~/Library/Logs/Reef/activity.log`, and `reefctl` (build it with
`swiftc Tools/reefctl.swift -o build/reefctl`) sends debug commands to the running app: `dump`, `others`, `probe`, `probe <bundle id>`, `tree <bundle id>`, `thumbs`,
`press <n>`, `otherapps`, `release`, `focus <window id>`.


## FAQ
<details>
<summary><b>Why is it called "Reef"?</b></summary>
<br>
The name comes from the starting sounds of the words "refocus" and "reframe". And, like a coral reef supports a diverse ecosystem, Reef supports your workspace—helping you navigate between windows quickly and easily.
</details>


## Related Projects
- [yabai](https://github.com/asmvik/yabai)
- [Aerospace](https://github.com/nikitabobko/AeroSpace?tab=readme-ov-file)
- [Rectangle](https://github.com/rxhanson/Rectangle)
- [AltTab for macOS](https://github.com/lwouis/alt-tab-macos/tree/master)
