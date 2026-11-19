#!/bin/sh
# Adds the agent-status hooks to Claude Code and Codex, and the SwiftBar plugin.
# Safe to run again: it replaces its own entries and backs up every file it changes.
exec "$(cd "$(dirname "$0")" && pwd)/bin/agent-status" install
