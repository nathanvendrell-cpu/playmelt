"""Synthetic Valve cache records; no client, account, network or executable."""
import pathlib
import struct
import sys
import tempfile
import unittest

sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]/"scripts"))
from steam_appinfo import read_appinfo


def cache(version):
    app={"appinfo":{"common":{"name":"Fixture","oslist":"windows"},
                    "config":{"launch":{"0":{"executable":"Game.exe"}}},
                    "depots":{"11":{"manifests":{"public":{"gid":"123","size":"2"}}}},
                    "ignored-private-header-fixture":"not exported"}}
    keys=[]
    def collect(d):
        for k,v in d.items():
            if k not in keys:keys.append(k)
            if isinstance(v,dict):collect(v)
    collect(app)
    def obj(d):
        result=b""
        for k,v in d.items():
            key=struct.pack('<I',keys.index(k)) if version==29 else k.encode()+b'\0'
            result+=bytes([0 if isinstance(v,dict) else 1])+key
            result+=obj(v) if isinstance(v,dict) else v.encode()+b'\0'
        return result+b'\x08'
    body=obj(app);prefix=68 if version>=28 else 48
    record=struct.pack('<II',10,prefix-8+len(body))+b'ACCESS-TOKEN-NOT-EXPORTED'.ljust(prefix-8,b'\0')+body
    if version==29:
        table=struct.pack('<I',len(keys))+b''.join(k.encode()+b'\0' for k in keys)
        return struct.pack('<IIQ',0x07564429,1,16+len(record))+record+table
    return struct.pack('<II',{27:0x07564427,28:0x07564428}[version],1)+record


class CacheTests(unittest.TestCase):
    def test_three_supported_formats_and_header_isolation(self):
        for version in (27,28,29):
            with self.subTest(version=version),tempfile.TemporaryDirectory() as directory:
                path=pathlib.Path(directory)/'appinfo.vdf';path.write_bytes(cache(version))
                data=read_appinfo(path)
                self.assertEqual(data['10']['config']['launch']['0']['executable'],'Game.exe')
                self.assertNotIn('ACCESS-TOKEN',repr(data))
                self.assertNotIn('ignored-private-header-fixture',repr(data))
                self.assertEqual(read_appinfo(path,{'20'}),{})

    def test_truncated_and_invalid_indexes_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            path=pathlib.Path(directory)/'appinfo.vdf'
            for data in (cache(28)[:-2],cache(29)[:24],b'not a Valve cache'):
                path.write_bytes(data)
                with self.assertRaises(ValueError):read_appinfo(path)

    def test_symlink_cache_is_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            path=pathlib.Path(directory)/'source';path.write_bytes(cache(29))
            link=path.with_name('appinfo.vdf');link.symlink_to(path)
            with self.assertRaises(ValueError):read_appinfo(link)


if __name__=='__main__':unittest.main()
