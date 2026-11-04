//
//  main.swift
//  MalinoisVerifier
//
//  The Mac verifier's program (BACKLOG item 90, phase 5): `malinois-verify BUNDLE [--root ROOT]`. What it does is
//  `MalinoisVerifier.run`, which the tests call; this prints its report and ends with its status.
//

import Foundation

let outcome = MalinoisVerifier.run(Array(CommandLine.arguments.dropFirst()))
FileHandle.standardOutput.write(Data(outcome.text.utf8))
exit(outcome.status)
