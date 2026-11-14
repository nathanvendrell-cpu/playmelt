"""Conservative, side-effect-free policy for a private Wine test supervisor.

This module does not create a prefix, run Wine, signal processes or prove cleanup.
It must not be presented as the missing runtime supervisor.
"""
from dataclasses import dataclass
from pathlib import Path
from uuid import UUID

@dataclass(frozen=True)
class ProcessIdentity:
    pid: int
    uid: int
    start_sec: int
    start_usec: int
    executable: str

@dataclass(frozen=True)
class PrivateScope:
    run_id: str
    uid: int
    root: str
    prefix: str
    engine: str

    def validate(self, products: str) -> None:
        UUID(self.run_id)
        base, root, prefix, engine = map(Path, (products, self.root, self.prefix, self.engine))
        if not all(p.is_absolute() and '..' not in p.parts for p in (base, root, prefix, engine)):
            raise ValueError('absolute normalized paths required')
        if root.parent != base or not root.name.startswith('m3-wine-' + self.run_id + '-') or len(root.name) <= len('m3-wine-' + self.run_id + '-') or prefix != root / 'prefix':
            raise ValueError('prefix must be inside the run-specific private directory')
        if self.uid < 0:
            raise ValueError('invalid uid')

    def environment(self, canonical_plan: dict[str, str]) -> dict[str, str]:
        if not canonical_plan.get('CX_D3DMETALPATH') or not canonical_plan.get('WINEDLLPATH_PREPEND'):
            raise ValueError('missing verified canonical D3DMetal plan')
        result = dict(canonical_plan)
        result.update(WINEPREFIX=self.prefix, HOME=str(Path(self.root) / 'home'),
                      PLAYMELT_TEST_RUN=self.run_id, ROSETTA_ADVERTISE_AVX='1')
        return result

    def shutdown_commands(self, wine_server: str) -> tuple[tuple[str, ...], ...]:
        expected = str(Path(self.engine) / 'bin' / 'wineserver')
        if wine_server != expected:
            raise ValueError('only the canonical engine wineserver is permitted')
        return ((wine_server, '-k'), (wine_server, '-w'))


def safe_identity_match(recorded: ProcessIdentity, observed: ProcessIdentity) -> bool:
    """A reused PID or changed executable is not the process originally observed."""
    return recorded == observed and recorded.pid > 1 and recorded.start_sec > 0
