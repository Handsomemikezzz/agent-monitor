#!/bin/sh
# Removes only the agent-status hooks and the SwiftBar plugin; other hooks stay.
exec "$(cd "$(dirname "$0")" && pwd)/bin/agent-status" uninstall
