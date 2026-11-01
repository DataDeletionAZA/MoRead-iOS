# Current implementation and validation

Snapshot: 2026-11-01. This is a development build for iOS 17 and later.

## Source and build

- iOS source: https://github.com/DataDeletionAZA/MoRead-iOS
- Original reference: https://github.com/DataDeletionAZA/MoRead
- Later Android reference: ovo066/MoRead v1.3.0, commit `f4b4fe2e94593f6de08bf3ed0ea3153f9457efdd`.
- `project.yml` describes the Xcode project. Generate it with XcodeGen when changing the application or UI-test file set.
- Open `MoRead.xcodeproj`, select the `MoRead` scheme and an iPhone simulator, then run. Installing on a physical iPhone additionally requires selecting a signing team in Xcode.
- `Package.resolved` and the Xcode workspace's Swift package lockfile record dependency versions. `README.md` describes implemented capabilities and their validation boundaries.

## Latest functionality

- Gemini voice library, online catalog, recoverable voice design and bounded AI voice-design tools.
- Privacy-preserving AI chapter-rule suggestions for TXT import, with local full-book validation and explicit application in the import preview.
- LAN transfer through a local HTTP listener, authenticated browser uploads, persistent staging and the existing book-import flow.

## Recorded checks

These results are from 2026-10-04, not a new full-suite run on the snapshot date.

- All 206 core tests passed before the final LAN quota-accounting adjustment; the three focused LAN tests passed after that adjustment.
- Two LAN simulator tests passed: completed-file retention/import/restart, and listener shutdown/reopening. The simulator application build also passed after the final quota adjustment and debug launch route.
- AI chapter-rule import flows passed focused simulator checks, and GitHub Actions run `37219539265` succeeded.
- GitHub Actions run `37218310563` failed in `VoiceLibraryUITests/testDesignVoiceRecoverPreviewRenameSaveAndRestart`: after tapping save, the test observed `满意，入库` instead of `已保存到音色库` at `UITests/VoiceLibraryTests.swift:132`. The cause remains unresolved; local simulator success does not establish compatibility with that cloud runner.

## Open implementation and acceptance work

- Multi-character audiobook: dialogue attribution, casting and per-character playback.
- Illustration studio: consistent character references, appearance versions, reusable styles and resumable chapter batches.
- WebDAV backup and synchronization.
- Advanced reader styling, complex EPUB compatibility and remaining Android feature parity.
- LAN browser interaction, real Wi-Fi transfer and physical-device local-network permission.
- Real AI/TTS provider behavior, long-running background/lock-screen playback, photo/file pickers and final physical-iPhone acceptance.

The working application and test fixtures are source-controlled. Build products, fetched dependencies and simulator operating-system state can be recreated; they are not substitutes for the source or for user library backups. iPhone library data resides on that device and is separate from this source snapshot.
