// macos/WatchApproveMac/App/main.swift
import AppKit
let app = NSApplication.shared
let delegate = WatchApproveMacAppDelegate()
app.delegate = delegate
app.run()
