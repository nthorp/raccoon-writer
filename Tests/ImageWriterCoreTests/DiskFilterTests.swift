import Foundation
import Testing
@testable import ImageWriterCore

struct DiskFilterTests {
    let boot = BootDiskSet.fixture
    let both = [DiskFilter(showAllExternal: false), DiskFilter(showAllExternal: true)]

    func rejections(_ disk: DiskInfo) -> [DiskRejection?] {
        both.map { $0.rejection(for: disk, bootDisks: boot) }
    }

    @Test func plainUSBStickPassesBothSettings() {
        #expect(rejections(.usbStick()) == [nil, nil])
    }

    @Test func alwaysAppliedRules() {
        var disk = DiskInfo.usbStick("disk4s1")
        #expect(rejections(disk) == [.invalidName, .invalidName])

        disk = .usbStick()
        disk.isWholeDisk = false
        #expect(rejections(disk) == [.notWholeDisk, .notWholeDisk])

        disk = .usbStick()
        disk.isInternal = true
        #expect(rejections(disk) == [.internalDisk, .internalDisk])

        disk = .usbStick()
        disk.isAPFSContainer = true
        #expect(rejections(disk) == [.apfsContainer, .apfsContainer])

        disk = .usbStick()
        disk.isVirtual = true
        #expect(rejections(disk) == [.virtualDisk, .virtualDisk])

        disk = .usbStick()
        disk.sizeBytes = 0
        #expect(rejections(disk) == [.noMedia, .noMedia])
    }

    @Test func externalUSBBootDiskIsNeverShown() {
        // Booted from a USB stick: every flag looks like a valid target.
        let externalBoot = BootDiskSet(["disk4", "disk6"])!
        for filter in both {
            #expect(filter.rejection(for: .usbStick(), bootDisks: externalBoot) == .bootDisk)
            #expect(filter.targets(from: [.usbStick(), .usbStick("disk5")], bootDisks: externalBoot).map(\.bsdName) == ["disk5"])
        }
    }

    @Test(arguments: ["/", "/System/Volumes/Data", "/System/Volumes/Preboot"])
    func systemVolumeMountedIsNeverShown(_ mountPoint: String) {
        // Backstop for a boot set that missed a disk.
        var disk = DiskInfo.usbStick()
        disk.mountPoints.append(mountPoint)
        #expect(rejections(disk) == [.systemVolume, .systemVolume])
    }

    @Test func systemMountPointMatching() {
        #expect(DiskFilter.isSystemMountPoint("/"))
        #expect(DiskFilter.isSystemMountPoint("/System/Volumes"))
        #expect(DiskFilter.isSystemMountPoint("/System/Volumes/VM"))
        #expect(!DiskFilter.isSystemMountPoint("/Volumes/System"))
        #expect(!DiskFilter.isSystemMountPoint("/System/VolumesX"))
        #expect(!DiskFilter.isSystemMountPoint("/Volumes/STICK"))
    }

    @Test func defaultModeRequiresUSBAndRemovableOrEjectable() {
        var disk = DiskInfo.usbStick()
        disk.busProtocol = "PCI-Express"
        #expect(rejections(disk) == [.notUSB, nil])

        disk = .usbStick()
        disk.busProtocol = nil
        #expect(rejections(disk) == [.notUSB, nil])

        disk = .usbStick()
        disk.isRemovable = false
        disk.isEjectable = false
        #expect(rejections(disk) == [.notRemovable, nil])

        disk = .usbStick()
        disk.isRemovable = false
        #expect(rejections(disk) == [nil, nil])
    }

    /// Records current behaviour (T20): USB hard drives and SSDs usually report
    /// ejectable but not removable, so they are listed by default and get a
    /// `LargeDriveWarning` instead. Changing this must be a deliberate decision.
    @Test func ejectableOnlyUSBHardDriveIsListedByDefault() {
        var disk = DiskInfo.usbStick(sizeBytes: 1_000_204_886_016)
        disk.isRemovable = false
        disk.isEjectable = true
        #expect(DiskFilter(showAllExternal: false).rejection(for: disk, bootDisks: boot) == nil)
    }
}
