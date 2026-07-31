//
//  FileShareSheet.swift
//  VVTerm
//
//  Shared model for presenting the platform share UI for a local file.
//  Platform presentation lives in FileShareSheet+iOS/macOS.
//

import Foundation

struct FileShareItem: Identifiable {
    let id = UUID()
    let fileURL: URL
}
