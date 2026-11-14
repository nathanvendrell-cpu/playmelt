"""Read public installation metadata from Steam's local cache, never credentials.

The access-token/header fields are skipped and are never returned.
"""
from pathlib import Path


def read_appinfo(path, wanted=None):
    path = Path(path)
    if path.is_symlink() or not 16 <= path.stat().st_size < 64_000_000:
        raise ValueError("Cache Steam invalide")
    data = path.read_bytes()

    def number(pos, size, end=None):
        if pos < 0 or pos + size > (len(data) if end is None else end):
            raise ValueError("Cache Steam tronqué")
        return int.from_bytes(data[pos:pos + size], "little")

    def string(pos, end):
        stop = data.find(b"\0", pos, end)
        if stop < 0 or stop - pos > 65536:
            raise ValueError("Chaîne Steam invalide")
        return data[pos:stop].decode("utf-8", "strict"), stop + 1

    magic = number(0, 4)
    if magic not in (0x07564427, 0x07564428, 0x07564429):
        raise ValueError("Version du cache Steam non prise en charge")
    strings, end, pos = [], len(data), 8
    if magic == 0x07564429:
        end = number(8, 8)
        if not 16 <= end < len(data):
            raise ValueError("Index Steam invalide")
        cursor = end
        count = number(cursor, 4)
        cursor += 4
        if count > 100000:
            raise ValueError("Index Steam trop grand")
        for _ in range(count):
            value, cursor = string(cursor, len(data))
            strings.append(value)
        pos = 16

    def obj(cursor, limit, depth=0):
        if depth >= 48:
            raise ValueError("Cache Steam trop imbriqué")
        result = {}
        while cursor < limit:
            kind = number(cursor, 1, limit)
            cursor += 1
            if kind == 8:
                return result, cursor
            if strings:
                key_id = number(cursor, 4, limit)
                cursor += 4
                if key_id >= len(strings):
                    raise ValueError("Clé Steam invalide")
                key = strings[key_id]
            else:
                key, cursor = string(cursor, limit)
            if kind == 0:
                value, cursor = obj(cursor, limit, depth + 1)
            elif kind == 1:
                value, cursor = string(cursor, limit)
            elif kind in (2, 3, 4, 6):
                value = str(number(cursor, 4, limit))
                cursor += 4
            elif kind in (7, 10):
                value = str(number(cursor, 8, limit))
                cursor += 8
            else:
                raise ValueError("Type Steam non pris en charge")
            result[key] = value
        raise ValueError("Objet Steam incomplet")

    result = {}
    while pos + 8 <= end:
        appid = number(pos, 4, end)
        if not appid:
            break
        size = number(pos + 4, 4, end)
        stop = pos + 8 + size
        body = pos + (68 if magic >= 0x07564428 else 48)
        if not body < stop <= end:
            raise ValueError("Enregistrement Steam incomplet")
        if wanted is None or str(appid) in wanted:
            root, _ = obj(body, stop)
            app = root.get("appinfo", {})
            if isinstance(app, dict):
                # Explicit public-metadata allowlist; record headers omitted.
                result[str(appid)] = {k: app[k] for k in ("common", "config", "depots", "extended") if k in app}
        pos = stop
    return result
