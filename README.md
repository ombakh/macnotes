# MacNotes (Menu Bar Notes for macOS)

MacNotes is a native SwiftUI menu bar app that opens from the top toolbar and stores notes locally.

## What it includes

- Menu bar icon with:
  - Left click: open/close notes window
  - Right click: quick menu (`Show/Hide Notes`, `New Note`, `Quit`)
- Dock-hidden utility app behavior
- Glass-style UI with materials, borders, shadows, and gradient backdrop
- Search, folders, create, edit, move, and delete note flows
- Local persistence as one `.txt` file per note in `/Users/ombakhshi/Desktop/macnotes/SavedNotes/`

## Run in Xcode

1. Open Xcode.
2. Choose **File > Open...** and select `/Users/ombakhshi/Desktop/macnotes/Package.swift`.
3. Select the `macnotes` scheme.
4. Press Run.
5. Click the **note icon** in the macOS menu bar to open the app.

## Install via Homebrew

This repo includes a Homebrew formula at `/Users/ombakhshi/Desktop/macnotes/Formula/macnotes.rb`.

From any terminal:

1. `brew tap ombakh/macnotes https://github.com/ombakh/macnotes`
2. `brew install --HEAD ombakh/macnotes/macnotes`
3. Launch the app with: `macnotes`

## Main code

- `/Users/ombakhshi/Desktop/macnotes/Sources/macnotes/macnotes.swift`
- `/Users/ombakhshi/Desktop/macnotes/Package.swift`
- `/Users/ombakhshi/Desktop/macnotes/.gitignore`
- `/Users/ombakhshi/Desktop/macnotes/Formula/macnotes.rb`
