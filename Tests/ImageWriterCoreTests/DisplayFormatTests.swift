import Foundation
import Testing
@testable import ImageWriterCore

struct DisplayFormatTests {
    @Test(arguments: [
        (UInt64(0), "0 bytes"),
        (1, "1 byte"),
        (999, "999 bytes"),
        (1000, "1 KB"),
        (1_500, "1.5 KB"),
        (999_960, "1 MB"),
        (4_700_000_000, "4.7 GB"),
        (16_008_609_792, "16 GB"),
        (30_752_636_928, "30.8 GB"),
        (128_000_000_000, "128 GB"),
        (2_000_398_934_016, "2 TB"),
    ])
    func sizes(_ bytes: UInt64, _ expected: String) {
        #expect(DisplayFormat.size(bytes) == expected)
    }

    @Test func speeds() {
        #expect(DisplayFormat.speed(nil) == "—")
        #expect(DisplayFormat.speed(.nan) == "—")
        #expect(DisplayFormat.speed(-1) == "—")
        #expect(DisplayFormat.speed(38_249_000) == "38.2 MB/s")
        #expect(DisplayFormat.speed(512) == "512 bytes/s")
    }

    @Test func percentNeverRoundsUpTo100() {
        #expect(DisplayFormat.percent(0) == "0 %")
        #expect(DisplayFormat.percent(0.425) == "42 %")
        #expect(DisplayFormat.percent(0.999) == "99 %")
        #expect(DisplayFormat.percent(1) == "100 %")
        #expect(DisplayFormat.percent(1.5) == "100 %")
        #expect(DisplayFormat.percent(-0.1) == "0 %")
        #expect(DisplayFormat.percent(.nan) == "0 %")
    }

    @Test(arguments: [
        (0.0, "0 s"),
        (8.4, "8 s"),
        (59.6, "1 min 00 s"),
        (185, "3 min 05 s"),
        (3_720, "1 h 02 min"),
        (-5, "0 s"),
    ])
    func durations(_ seconds: Double, _ expected: String) {
        #expect(DisplayFormat.duration(seconds) == expected)
    }

    @Test func remainingTime() {
        #expect(DisplayFormat.remaining(nil) == "—")
        #expect(DisplayFormat.remaining(.infinity) == "—")
        #expect(DisplayFormat.remaining(0) == "Less than a minute left")
        #expect(DisplayFormat.remaining(59) == "Less than a minute left")
        #expect(DisplayFormat.remaining(61) == "About 2 min left")
        #expect(DisplayFormat.remaining(3_540) == "About 59 min left")
        #expect(DisplayFormat.remaining(3_600) == "About 1 h 00 min left")
        #expect(DisplayFormat.remaining(3_700) == "About 1 h 02 min left")
    }

    @Test func mountPoints() {
        var disk = DiskInfo.usbStick()
        disk.mountPoints = ["/Volumes/STICK", "/Volumes/DATA"]
        #expect(DisplayFormat.mountPoints(of: disk) == "/Volumes/STICK, /Volumes/DATA")
        disk.mountPoints = []
        #expect(DisplayFormat.mountPoints(of: disk) == "none")
    }

    @Test func volumeNames() {
        var disk = DiskInfo.usbStick()
        disk.volumeNames = ["STICK", "DATA", "EFI"]
        #expect(DisplayFormat.volumeNames(of: disk) == "STICK, DATA, EFI")
        disk.volumeNames = ["STICK"]
        #expect(DisplayFormat.volumeNames(of: disk) == "STICK")
        disk.volumeNames = []
        #expect(DisplayFormat.volumeNames(of: disk) == nil)
    }

    /// Names are user-controlled; they must come back as typed, not escaped or parsed.
    @Test func volumeNamesWithMarkdownCharactersAreUnchanged() {
        var disk = DiskInfo.usbStick()
        disk.volumeNames = ["*BOLD*", "[link](x)"]
        #expect(DisplayFormat.volumeNames(of: disk) == "*BOLD*, [link](x)")
    }
}
