"""Unit tests for Inode telemetry collector."""

from agent.collector.inode import InodeCollector
from agent.models import MetricType


def test_inode_collector_parsing_and_fat32_handling(mock_proc_dir, mock_statvfs):
    """Test inode metrics collection, verifying ext4 inodes and FAT32 zero-inode safety."""
    collector = InodeCollector(
        proc_path=mock_proc_dir,
        statvfs_func=mock_statvfs,
    )
    families = collector.collect()
    fam_dict = {f.name: f for f in families}

    assert "linux_inode_total" in fam_dict
    total_fam = fam_dict["linux_inode_total"]
    assert total_fam.type == MetricType.GAUGE

    assert "linux_inode_free" in fam_dict
    free_fam = fam_dict["linux_inode_free"]

    assert "linux_inode_used" in fam_dict
    used_fam = fam_dict["linux_inode_used"]

    # Check root ext4 mount: 10M total, 8M free, 2M used
    root_total = [s for s in total_fam.samples if s.labels.get("mountpoint") == "/"][0]
    assert root_total.value == 10000000

    root_free = [s for s in free_fam.samples if s.labels.get("mountpoint") == "/"][0]
    assert root_free.value == 8000000

    root_used = [s for s in used_fam.samples if s.labels.get("mountpoint") == "/"][0]
    assert root_used.value == 2000000

    # Check FAT32 /boot/efi mount: 0 total, 0 free, 0 used without error
    boot_total = [s for s in total_fam.samples if s.labels.get("mountpoint") == "/boot/efi"][0]
    assert boot_total.value == 0
    boot_free = [s for s in free_fam.samples if s.labels.get("mountpoint") == "/boot/efi"][0]
    assert boot_free.value == 0
    boot_used = [s for s in used_fam.samples if s.labels.get("mountpoint") == "/boot/efi"][0]
    assert boot_used.value == 0
