from __future__ import annotations

import re
from pathlib import Path
from tempfile import NamedTemporaryFile, TemporaryDirectory
from uuid import UUID

import pytest
from hypothesis import assume, given
from hypothesis import strategies as st
from pydantic import ValidationError

from butter_backup import config_parser as cp
from tests import hypothesis_utils as hu


@st.composite
def valid_unparsed_empty_btrfs_config(draw):
    config = draw(
        st.fixed_dictionaries(
            {
                "DevicePassCmd": st.text(),
                "Files": st.just([]),
                "FilesDest": st.text(),
                "Folders": st.just({}),
                "UUID": st.uuids().map(str),
            }
        )
    )
    return config


@given(uuid=st.uuids(), passphrase=st.text())
def test_btrfs_from_uuid_and_pashphrase(uuid: UUID, passphrase: str) -> None:
    config = cp.BtrfsConfig.from_uuid_and_passphrase(uuid, passphrase)
    assert config.Folders == {}
    assert config.Files == set()
    assert config.UUID == uuid
    assert passphrase in config.DevicePassCmd


@pytest.mark.xfail(reason="safety checks not yet implemented")
@given(
    uuid=st.uuids(),
    passphrase=st.sampled_from(
        ["contains_'quote", "contains;_semicolon", "contains&ampersand"]
    ),
)
def test_btrfs_from_uuid_and_passphrase_rejects_unsafe_passphrases(
    uuid: UUID,
    passphrase: str,
) -> None:
    with pytest.raises(ValueError):
        cp.BtrfsConfig.from_uuid_and_passphrase(uuid, passphrase)


@given(base_config=valid_unparsed_empty_btrfs_config(), dest_dir=hu.filenames())
def test_btrfs_config_rejects_file_dest_collision(base_config, dest_dir: str):
    base_config["Folders"] = {
        "/usr/bin": "backup_bins",
        "/etc": dest_dir,
        "/var/log": "backup_logs",
    }
    base_config["FilesDest"] = dest_dir
    with NamedTemporaryFile() as src:
        base_config["Files"] = [src.name]
        with pytest.raises(ValidationError, match=re.escape(dest_dir)):
            cp.BtrfsConfig.parse_obj(base_config)


@given(base_config=valid_unparsed_empty_btrfs_config(), file_name=hu.filenames())
def test_btrfs_config_rejects_filename_collision(base_config, file_name):
    base_config["Folders"] = {}
    with TemporaryDirectory() as td1:
        with TemporaryDirectory() as td2:
            dirs = [td1, td2]
            files = [Path(cur_dir) / file_name for cur_dir in dirs]
            for f in files:
                f.touch()
            base_config["Files"] = [str(f) for f in files]
            with pytest.raises(ValidationError, match=re.escape(file_name)):
                cp.BtrfsConfig.parse_obj(base_config)


@given(base_config=valid_unparsed_empty_btrfs_config())
def test_btrfs_config_expands_user(base_config):
    with TemporaryDirectory() as dest:
        pass
    folders = {
        "/usr/bin": "backup_bins",
        "~": dest,
        "/var/log": "backup_logs",
    }
    base_config["Folders"] = folders
    with NamedTemporaryFile(dir=Path.home()) as src_file:
        fname = f"~/{Path(src_file.name).name}"
        base_config["Files"] = ["/bin/bash", fname]
        cfg = cp.BtrfsConfig.parse_obj(base_config)
    assert Path("~").expanduser() in cfg.Folders
    assert Path(src_file.name).expanduser() in cfg.Files


@given(
    base_config=valid_unparsed_empty_btrfs_config(),
    folder_dest=hu.filenames(),
)
def test_btrfs_config_rejects_duplicate_dest(base_config, folder_dest: str):
    with TemporaryDirectory() as src1:
        with TemporaryDirectory() as src2:
            folders = {
                "/usr/bin": "backup_bins",
                src1: folder_dest,
                "/var/log": "backup_logs",
                src2: folder_dest,
            }
            base_config["Folders"] = folders
            base_config["Files"] = []
            with pytest.raises(ValidationError, match=re.escape(folder_dest)):
                cp.BtrfsConfig.parse_obj(base_config)


@given(base_config=valid_unparsed_empty_btrfs_config())
def test_btrfs_config_uuid_is_mapname(base_config) -> None:
    cfg = cp.BtrfsConfig.parse_obj(base_config)
    assert base_config["UUID"] == cfg.map_name()


@given(base_config=valid_unparsed_empty_btrfs_config())
def test_btrfs_config_device_ends_in_uuid(base_config) -> None:
    cfg = cp.BtrfsConfig.parse_obj(base_config)
    uuid = base_config["UUID"]
    assert cfg.device() == Path(f"/dev/disk/by-uuid/{uuid}")


@given(base_config=valid_unparsed_empty_btrfs_config(), folder_dest=hu.filenames())
def test_btrfs_config_json_roundtrip(base_config, folder_dest: str):
    assume(folder_dest != base_config["FilesDest"])
    with TemporaryDirectory() as src_folder:
        with NamedTemporaryFile() as src_file:
            base_config["Folders"] = {src_folder: folder_dest}
            base_config["Files"] = [src_file.name]
            cfg = cp.BtrfsConfig.parse_obj(base_config)
            as_json = cfg.json()
            deserialised = cp.BtrfsConfig.parse_raw(as_json)
    assert cfg == deserialised
