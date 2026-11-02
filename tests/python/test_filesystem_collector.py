"""Unit tests for Filesystem telemetry collector."""

from agent.collector.filesystem import FilesystemCollector
from agent.models import MetricType


def test_filesystem_collector_filtering_and_parsing(mock_proc_dir, mock_statvfs):
    """Test filesystem metrics collection, filtering out squashfs/tmpfs and calculating capacities."""
    collector = FilesystemCollector(
        proc_path=mock_proc_dir,
        statvfs_func=mock_statvfs,
    )
    families = collector.collect()
    fam_dict = {f.name: f for f in families}

    assert "linux_filesystem_size_bytes" in fam_dict
    size_fam = fam_dict["linux_filesystem_size_bytes"]
    assert size_fam.type == MetricType.GAUGE

    # In synthetic mounts:
    # - / (ext4) -> included
    # - /boot/efi (vfat) -> included
    # - /snap/core22/1621 (squashfs) -> EXCLUDED by fstype filter
    # - /run (tmpfs) -> EXCLUDED by fstype and mountpoint filter
    # - /sys, /proc -> EXCLUDED by fstype and mountpoint filter
    mountpoints = [s.labels.get("mountpoint") for s in size_fam.samples]
    assert "/" in mountpoints
    assert "/boot/efi" in mountpoints
    assert "/snap/core22/1621" not in mountpoints
    assert "/run" not in mountpoints
    assert "/sys" not in mountpoints
    assert "/proc" not in mountpoints

    # Check root mount calculation
    root_size = [s for s in size_fam.samples if s.labels.get("mountpoint") == "/"][0]
    # 26214400 blocks * 4096 = 107374182400 bytes (~100 GiB)
    assert root_size.value == 26214400 * 4096

    assert "linux_filesystem_avail_bytes" in fam_dict
    avail_fam = fam_dict["linux_filesystem_avail_bytes"]
    root_avail = [s for s in avail_fam.samples if s.labels.get("mountpoint") == "/"][0]
    assert root_avail.value == 9175040 * 4096

    assert "linux_filesystem_used_bytes" in fam_dict
    used_fam = fam_dict["linux_filesystem_used_bytes"]
    root_used = [s for s in used_fam.samples if s.labels.get("mountpoint") == "/"][0]
    # size - free = (26214400 - 10485760) * 4096
    assert root_used.value == (26214400 - 10485760) * 4096

    assert "linux_filesystem_readonly" in fam_dict
    ro_fam = fam_dict["linux_filesystem_readonly"]
    root_ro = [s for s in ro_fam.samples if s.labels.get("mountpoint") == "/"][0]
    assert root_ro.value == 0.0  # Not read-only
