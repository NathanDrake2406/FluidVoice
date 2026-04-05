# FluidVoice v1.5.12

## What's New
- Added `Transcribe with Prompt`, a new recording mode that lets you run dictation with a chosen AI prompt for that session without changing your global prompt selection.
- Simplified dictation AI controls by moving AI off/on into prompt selection with `Off`, `Default`, and custom prompts.
- Fixed AI post-processing so selecting a dictation prompt correctly counts as opting into AI, instead of silently skipping processing.
- Fixed overlay actions staying functional after the main settings window closes.


## Voice Engine Updates
- Added `Cohere Transcribe` as a new speech model option. Very accurate.( 14 languages but needs manual selection)
- Added `Parakeet Flash (Beta)`, a faster English-only local streaming model for low-latency live dictation.
- Improved Cohere performance with split Neural Engine/GPU execution and async chunk prefetch.
- Fixed Cohere model downloads and transcription failures.
- Added manual language selection for Cohere in Voice Engine settings.
- Added stronger validation for external Cohere artifacts so mismatched model contracts fail earlier and more clearly.

## File and Meeting Transcription
- Added OGG support for file transcription uploads and drag-and-drop.
- Expanded meeting transcription format support with broader macOS-native audio and video compatibility.

## Other Fixes
- Added manual backup export and import for app settings, prompt profiles, transcription history, and stats, with API keys excluded from backup files.
- Added a compact `Backup & Restore` utility row in Preferences for quicker export and import access.
- Added a configurable `Cancel Recording` shortcut in Settings, defaulting to `Escape`, so recording cancel behavior can be remapped without changing the rest of the shortcuts.
- Added microphone selection to the menu bar and synced microphone selection state between the menu bar and Settings.
- Fixed API key authentication for localhost and other local model endpoints that still require an `Authorization` header.
- Fixed the top notch overlay so it shows the active prompt name correctly during prompt-mode recording.

## Credits
- Thanks to @yelloduxx for the original prompt-mode and overlay work.
- Thanks to @kabhijeet for the localhost API auth fix in PR #233.
- Thanks to @daaain for the media format support contribution.

## Need Help?
- Report issues: https://github.com/altic-dev/FluidVoice/issues
