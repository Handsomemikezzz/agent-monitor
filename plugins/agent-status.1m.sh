#!/bin/sh
# SwiftBar plugin. install.sh writes a copy with absolute paths into your SwiftBar
# plugin folder; this file is for copying by hand. The hooks refresh the menu on
# every change, and the 1m in the name is only a fallback timer.
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
AGENT_STATUS_BIN="${AGENT_STATUS_BIN:-$HOME/agent-status/bin/agent-status}"
exec "$AGENT_STATUS_BIN" menu
