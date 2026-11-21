#!/bin/sh
# Removes only the agent-status hooks and the menu bar app's login item; other hooks stay.
exec "$(cd "$(dirname "$0")" && pwd)/bin/agent-status" uninstall
