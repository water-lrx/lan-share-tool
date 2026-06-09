import AppKit
import CoreImage
import Foundation

let text = CommandLine.arguments.dropFirst().joined(separator: " ")
guard !text.isEmpty, let data = text.data(using: .utf8) else {
  FileHandle.standardError.write(Data("Usage: qr.swift <text>\n".utf8))
  exit(2)
}

guard let filter = CIFilter(name: "CIQRCodeGenerator") else {
  FileHandle.standardError.write(Data("CIQRCodeGenerator is unavailable\n".utf8))
  exit(1)
}

filter.setValue(data, forKey: "inputMessage")
filter.setValue("M", forKey: "inputCorrectionLevel")

guard let output = filter.outputImage else {
  FileHandle.standardError.write(Data("Could not generate QR image\n".utf8))
  exit(1)
}

let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
let rep = NSCIImageRep(ciImage: scaled)
let image = NSImage(size: rep.size)
image.addRepresentation(rep)

guard
  let tiff = image.tiffRepresentation,
  let bitmap = NSBitmapImageRep(data: tiff),
  let png = bitmap.representation(using: .png, properties: [:])
else {
  FileHandle.standardError.write(Data("Could not encode QR image\n".utf8))
  exit(1)
}

FileHandle.standardOutput.write(png)
