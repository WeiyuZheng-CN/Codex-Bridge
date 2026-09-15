# Archived Components

This directory contains historical components retained for migration,
comparison, and rollback. Nothing under archive/ is loaded by the current
installer or the current four-card chooser.

## legacy-moon-bridge

This area preserves the previous Moon Bridge application files, its
license/build metadata, history-repair helpers, model/config templates, and
the original source archive. The source archive and executable are historical
artifacts; use them only when an old installation must be inspected or
migrated. The current product uses native DeepSeek, shared Transfer, and Local
Qwen3.6 routes instead.

## legacy-transfer-260902

This area preserves sanitized 260902 API Key Mode and auth.json example
templates. They contain placeholders, not user credentials. They are
compatibility references for an older station configuration and are not used
by the current shared Transfer profile.

## Rules

* Do not copy runtime state, sessions, databases, logs, Electron data, or
  credentials into this directory.
* Do not make archived components part of the active installer without first
  documenting the compatibility reason and testing the result.
* Keep the current source under core/, current documentation under docs/, and
  current provider references under references/.
* Preserve the original license files when redistributing the archived binary
  or source archive.
