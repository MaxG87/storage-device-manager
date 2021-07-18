from __future__ import annotations

import contextlib
import subprocess
from dataclasses import dataclass
from pathlib import Path
from tempfile import TemporaryDirectory

from butter_backup import shell_interface as sh


@dataclass(frozen=True)
class DecryptedDevice:
    device: Path
    map_name: str
    pass_cmd: str

    def __enter__(self) -> Path:
        decrypt_cmd = f"sudo cryptsetup open '{self.device}' '{self.map_name}'"
        subprocess.run(f"{self.pass_cmd} | {decrypt_cmd}", check=True, shell=True)
        return Path(f"/dev/mapper/{self.map_name}")

    def __exit__(self, exc, value, tb) -> None:
        decrypt_cmd = ["sudo", "cryptsetup", "close", self.map_name]
        sh.run_cmd(cmd=decrypt_cmd)


@contextlib.contextmanager
def mounted_device(device: Path):
    if is_mounted(device):
        unmount_device(device)
    with TemporaryDirectory() as td:
        mount_dir = Path(td)
        mount_btrfs_device(device, Path(mount_dir))
        yield Path(mount_dir)
        unmount_device(device)


def mount_btrfs_device(device: Path, mount_dir: Path) -> None:
    cmd: sh.StrPathList = [
        "sudo",
        "mount",
        "-o",
        "compress=zlib",
        device,
        mount_dir,
    ]
    sh.run_cmd(cmd=cmd)


def is_mounted(dest: Path) -> bool:
    return str(dest) in get_mounted_devices()


def get_mounted_devices() -> dict[str, Path]:
    raw_mounts = sh.run_cmd(cmd=["mount"], capture_output=True)
    mount_lines = raw_mounts.stdout.decode().splitlines()
    return {line.split()[0]: Path(line.split()[2]) for line in mount_lines}


def unmount_device(device: Path) -> None:
    cmd: sh.StrPathList = ["sudo", "umount", device]
    sh.run_cmd(cmd=cmd)