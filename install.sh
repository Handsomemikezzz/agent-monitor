#!/bin/sh
# Adds the agent-status hooks to your coding agents, then builds and starts the menu bar app.
# Safe to run again: it replaces its own entries and backs up every file it changes.
exec "$(cd "$(dirname "$0")" && pwd)/bin/agent-status" install
