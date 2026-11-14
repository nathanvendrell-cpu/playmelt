import sys
from pathlib import Path
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
import gpu_identity_transaction_policy as p

class FakeRegistry:
    def __init__(self,value): self.value=value; self.writes=[]
    def read(self,instance,name): return self.value
    def write(self,instance,name,value): self.value=value;self.writes.append((instance,name,value))

class TransactionTests(unittest.TestCase):
    def setUp(self):
        self.instance=r'PCI\VEN_106B&DEV_03F1&SUBSYS_00000000&REV_00\00000000'
        self.original=p.Value('REG_SZ','Apple M3 Max')
        self.plan=p.prepare(self.instance,self.original,0x1002,0x66af,'AMD Compatibility Mode')
    def test_restore_on_success(self):
        b=FakeRegistry(self.original)
        def body(): self.assertEqual(b.value,self.plan.replacement)
        p.with_temporary_value(b,self.plan,body)
        self.assertEqual(b.value,self.original); self.assertEqual(len(b.writes),2)
        self.assertTrue(all(name=='DeviceDesc' for _,name,_ in b.writes))
    def test_restore_on_exception(self):
        b=FakeRegistry(self.original)
        def body(): raise RuntimeError('simulated failure')
        with self.assertRaises(RuntimeError): p.with_temporary_value(b,self.plan,body)
        self.assertEqual(b.value,self.original)
    def test_reject_stale_and_concurrent_modification(self):
        b=FakeRegistry(p.Value('REG_SZ','different'))
        with self.assertRaises(p.Conflict): p.with_temporary_value(b,self.plan,lambda:None)
        self.assertEqual(b.writes,[])
        b=FakeRegistry(self.original)
        def body(): b.value=p.Value('REG_SZ','other writer')
        with self.assertRaises(p.Conflict): p.with_temporary_value(b,self.plan,body)
        self.assertEqual(b.value.data,'other writer'); self.assertEqual(len(b.writes),1)
    def test_plan_refuses_unproven_identity(self):
        for v,d in [(0x106b,0x03f1),(0x1002,1)]:
            with self.assertRaises(ValueError): p.prepare(self.instance,self.original,v,d,'AMD Compatibility Mode')
        with self.assertRaises(ValueError): p.prepare(self.instance,self.original,0x1002,0x66af,'different')

if __name__=='__main__': unittest.main()
