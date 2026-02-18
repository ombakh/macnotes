# MacNotes (Menu Bar Notes for macOS)

MacNotes is a native SwiftUI menu bar app that opens from the top toolbar and stores notes locally.

## What it includes

- Top-toolbar entry via `MenuBarExtra`
- Dock-hidden utility app behavior
- Glass-style UI with materials, borders, shadows, and gradient backdrop
- Search, create, edit, and delete note flows
- Local persistence as one `.txt` file per note in `/Users/ombakhshi/Desktop/macnotes/SavedNotes/`

## Run in Xcode

1. Open Xcode.
2. Choose **File > Open...** and select `/Users/ombakhshi/Desktop/macnotes/Package.swift`.
3. Select the `macnotes` scheme.
4. Press Run.
5. Click the **note icon** in the macOS menu bar to open the app.

## Main code

- `/Users/ombakhshi/Desktop/macnotes/Sources/macnotes/macnotes.swift`
- `/Users/ombakhshi/Desktop/macnotes/Package.swift`
- `/Users/ombakhshi/Desktop/macnotes/.gitignore`
