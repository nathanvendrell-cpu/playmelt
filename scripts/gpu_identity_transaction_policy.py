"""Offline transaction model, no real registry adapter and no live mutation.

A possible future experiment concerns only DeviceDesc, never PCI IDs, driver
versions, resource levels or feature capabilities. Its causal value is unknown.
"""
from dataclasses import dataclass
from typing import Protocol, Callable

@dataclass(frozen=True)
class Value:
    kind: str
    data: str

@dataclass(frozen=True)
class Plan:
    instance: str
    original: Value
    replacement: Value
    expected_dxgi_vendor: int
    expected_dxgi_device: int

class Backend(Protocol):
    def read(self, instance: str, name: str) -> Value | None: ...
    def write(self, instance: str, name: str, value: Value) -> None: ...

class Conflict(RuntimeError): pass


def prepare(instance: str, current: Value, dxgi_vendor: int, dxgi_device: int,
            dxgi_description: str) -> Plan:
    expected = r'PCI\VEN_106B&DEV_03F1&SUBSYS_00000000&REV_00\00000000'
    if (instance.upper()!=expected.upper() or current!=Value('REG_SZ','Apple M3 Max') or
        (dxgi_vendor,dxgi_device)!=(0x1002,0x66af) or dxgi_description!='AMD Compatibility Mode'):
        raise ValueError('observations differ from the reviewed hypothesis; no plan')
    return Plan(instance,current,Value('REG_SZ',dxgi_description),dxgi_vendor,dxgi_device)


def with_temporary_value(backend: Backend, plan: Plan, body: Callable[[], None]) -> None:
    """Fake-backend only: compare, set, run, restore in finally; detect races.

    This proves ordinary exception behavior only. A real process crash or kill
    needs a durable scoped recovery journal and verified Wine state.
    """
    name='DeviceDesc'
    if backend.read(plan.instance,name)!=plan.original: raise Conflict('original value changed')
    try:
        backend.write(plan.instance,name,plan.replacement)
        if backend.read(plan.instance,name)!=plan.replacement: raise Conflict('write did not persist')
        body()
    finally:
        current=backend.read(plan.instance,name)
        if current==plan.replacement:
            backend.write(plan.instance,name,plan.original)
            if backend.read(plan.instance,name)!=plan.original: raise Conflict('restore not confirmed')
        elif current!=plan.original:
            raise Conflict('value changed concurrently; no overwrite')
