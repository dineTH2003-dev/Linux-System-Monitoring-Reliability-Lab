"""Unit tests for Disk I/O telemetry collector."""

from agent.collector.disk_io import DiskIOCollector
from agent.models import MetricType


def test_disk_io_collector_parsing_and_filtering(mock_proc_dir):
    """Test parsing of /proc/diskstats and loop device exclusion."""
    collector = DiskIOCollector(proc_path=mock_proc_dir)
    families = collector.collect()
    fam_dict = {f.name: f for f in families}

    assert "linux_disk_reads_completed_total" in fam_dict
    reads_fam = fam_dict["linux_disk_reads_completed_total"]
    assert reads_fam.type == MetricType.COUNTER

    # Devices present should be sda and nvme0n1. loop0 must be EXCLUDED.
    devices = [s.labels.get("device") for s in reads_fam.samples]
    assert "sda" in devices
    assert "nvme0n1" in devices
    assert "loop0" not in devices

    # Check sda samples:
    # line: 8 0 sda 1000 100 20000 5000 2000 200 40000 10000 0 15000 20000
    sda_reads = [s for s in reads_fam.samples if s.labels.get("device") == "sda"][0]
    assert sda_reads.value == 1000

    assert "linux_disk_writes_completed_total" in fam_dict
    writes_fam = fam_dict["linux_disk_writes_completed_total"]
    sda_writes = [s for s in writes_fam.samples if s.labels.get("device") == "sda"][0]
    assert sda_writes.value == 2000

    # Sector to byte conversion: sectors read = 20000 * 512 = 10240000 bytes
    assert "linux_disk_read_bytes_total" in fam_dict
    read_fam = fam_dict["linux_disk_read_bytes_total"]
    sda_rbytes = [s for s in read_fam.samples if s.labels.get("device") == "sda"][0]
    assert sda_rbytes.value == 20000 * 512.0

    # Sectors written = 40000 * 512 = 20480000 bytes
    assert "linux_disk_written_bytes_total" in fam_dict
    written_fam = fam_dict["linux_disk_written_bytes_total"]
    sda_wbytes = [s for s in written_fam.samples if s.labels.get("device") == "sda"][0]
    assert sda_wbytes.value == 40000 * 512.0

    # I/O time: 15000 ms / 1000 = 15.0 s
    assert "linux_disk_io_time_seconds_total" in fam_dict
    time_fam = fam_dict["linux_disk_io_time_seconds_total"]
    sda_time = [s for s in time_fam.samples if s.labels.get("device") == "sda"][0]
    assert sda_time.value == 15.0

    # In progress: 0 on sda, 2 on nvme0n1
    assert "linux_disk_io_in_progress" in fam_dict
    prog_fam = fam_dict["linux_disk_io_in_progress"]
    nvme_in_prog = [s for s in prog_fam.samples if s.labels.get("device") == "nvme0n1"][0]
    assert nvme_in_prog.value == 2.0
