# UX specs

Black-box specs of the built app, with real input, real windows and real apps. They prove only
what the real app can prove; `swift test` and the UI contract (`scripts/ui-check.sh`) pin the
rest without a screen. `scripts/ux-vms.sh` runs them in two VMs at the same time, each half
under the 180 s limit of `scripts/ux.sh`. The checks are in points, so they pass on a 1x and a
2x screen.

## Flows

First VM (`tilde-ux`):

| Spec | What only the real app proves |
| --- | --- |
| `anAgentOpensAPageTheUserNotesItAndTheAgentGetsAReportWithImages` | An MCP agent opens Tilde's browser; a note reaches it with images. |
| `aRectangleLeavesALabelThatHidesOnAnotherPageAndACrashLeavesOnlyItsNote` | A label follows another app's window and page, and its checks put no window sharing window in that app; a crash restores only the note. |
| `twoClipsReachTheAgentAsVideos` | Screen and window clips, the window picker's first open, and pause, Esc and send; a window's clip keeps to the window when it moves; the window's app gets no window sharing window. |
| `escTwiceOnAShapesCommentKeepsTypingInTheBox` | The keyboard stays in the comment box; Draw keeps it over a full-screen app. |
| `doubleControlInATextFieldGivesTheHUDTheKeys` | Double Ctrl takes the keys from another app's text field, also in full screen. |
| `aWireframeOnAWindowReachesTheAgentWithItsTwoPictures` | Snapping, the window behind, components that keep to a moving window, the report. |
| `settingsOpenWithNoFieldFocused` | Settings takes no field focus when it opens. |
| `settingsWorkAsUsualDuringASession` | Settings is a window, never annotated, during a session. |
| `theStyleControlsInTheBarChangeTheLookAtOnce` | The bar's style controls change the components on screen at once. |
| `eachCornerResizesAPartTheTopGripMovesItAndADragStartsWhereItWasPressed` | Real drags resize and move a part; no frame of a drag shows it on the wrong side. |
| `anUpdateInstallsWhenTildeQuitsAndTildeOpensAsTheNewVersion` | Sparkle installs on quit; the new version keeps its permissions. |

Second VM (`tilde-ux-2`):

| Spec | What only the real app proves |
| --- | --- |
| `aClickInAnotherBrowserOffersTildesBrowserWhichUnloadsThePageOnClose` | Safari's page opens in Tilde's browser, which unloads it on close. |
| `aNodeIsInstalledFromSettingsAndLinkedByItsSocket` | A remote machine over ssh: install, socket, drops and the report. |
| `anUpdateInstallsByItselfWhenTildeIsNotInUseAndNeverDuringASession` | Sparkle downloads and installs by itself, never during a session. |
| `aCopiedReportGoesToTheRemoteMachineWithItsImages` | A copied report's images go to the machine over ssh. |
| `aPasteInACommentBoxLandsInTheSystemsFocusedTextAndFocusGoesBackAfter` | A dictation app's paste lands in the focused text; focus goes back after. |
| `theHUDShowsOverAnAppInFullScreenWhoseWindowRecordsWhileTheUserTypesInIt` | Over a full-screen app the HUD is drawn on its Space and takes the keys; its window records until Stop while the user types in it; the app gets no window sharing window, on which AppKit asserts in some apps, and they crash. |

## Dropped

| Spec | Why |
| --- | --- |
| `aStyleChosenInSettingsShowsOnTheWireframe` | The bar spec proves the same path: both write the same settings, and the canvas redraws on any change. The contract pictures pin each style. |
| `resetPutsTheColoursAndStrengthsBack` | A unit test (`resetPutsTheColoursAndStrengthsBackAndKeepsTheStyle`) and the Appearance pictures pin it. |
| `anUpdateSignedWithAnotherKeyIsRefused` | A unit test runs the real Sparkle check on a zip that another key signed and pins the message (`aDownloadThatAnotherKeySignedFailsAsABadSignature`); the picture `settings-update-failed-light` pins the failed state. |
| `theSourcePickerListsTheScreensAndWindowsOnTheFirstOpen` | Merged, with all its checks: `twoClipsReachTheAgentAsVideos` opens the picker first after its launch and finds the window there. |
| `aDragStartsWhereItWasPressed` | Merged, with all its checks, into the corner spec, which draws the same card first. |

## Before a run

`scripts/ux-vm.sh` dates the test apps' screen capture approvals now and quits System Settings
in the VM (`scripts/ux-vm-approve.sh`). If a macOS question is on the VM's screen, the run stops
with a message; the specs never click it.
