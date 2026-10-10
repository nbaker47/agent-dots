# Agent Dots

A glass strip on the edge of the screen with one dot for each agent session running in cmux. It floats over
every window and Space.

- Blue, breathing: working. Amber, ringing: needs you. Green: finished, not looked at yet. Grey: idle.
- Point at the strip and it opens into the list: name, state, how long, workspace.
- Click a dot or a row to open that session's pane in cmux.
- The speech bubble on a row sends that agent a message (`cmux agent message`: delivered through the
  agent's hooks, never typed into its terminal).
- Right-click the strip: move it to the other edge, open at login, quit.

It reads the state files the cmux status hook writes (`~/.config/cmux/conductor-sidebar/cmux-status.sh`,
one file a pane under `~/.cache/cmux-status/`) and the pane titles from `cmux tree`. It installs no hook
and changes no setting.

Build and install: `sh build.sh` (needs macOS 26 for the glass, and Xcode's Swift).
