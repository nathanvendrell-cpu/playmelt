"""Offline checks: publisher scripts are inspected, never executed."""
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
from steam_prerequisites import inspect_scripts,detect_renderer,vdf
from audit_steam_requirements import profile


class PrerequisiteTests(unittest.TestCase):
    def test_exact_registry_view_and_architecture_are_preserved(self):
        key=r'HKEY_LOCAL_MACHINE\SOFTWARE\Wow6432Node\Valve\Steam\Apps\CommonRedist\vcredist\2022'
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)
            script={'Run Process':{'vc2022x64':{'HasRunKey':key,'MinimumHasRunValue':'2','Process 1':'never.exe'}}}
            def encode(obj):
                return ' '.join(json.dumps(k)+(' { '+encode(v)+' }' if isinstance(v,dict) else ' '+json.dumps(v)) for k,v in obj.items())
            (p/'installscript.vdf').write_text('"InstallScript" { '+encode(script)+' }')
            with patch('subprocess.run',side_effect=AssertionError('No execution')):
                checks,tasks=inspect_scripts(p,'99')
            self.assertEqual(tasks,[])
            self.assertEqual(checks[0]['key'],key)
            self.assertEqual(checks[0]['name'],'vc2022x64')
            self.assertEqual(checks[0]['minimum'],2)
            self.assertEqual(checks[0]['signatureValidation'],'Steam-client-required')

    def test_unverifiable_scripts_remain_typed_pending_work(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)
            (p/'script.vdf').write_text('"InstallScript" { "Run Process" { "component" { "HasRunKey" "HKEY_CURRENT_USER\\\\untrusted" "Process 1" "touch sentinel" } } }')
            checks,tasks=inspect_scripts(p,'99')
            self.assertEqual(checks,[])
            self.assertTrue(tasks)
            self.assertTrue(all(t['kind']=='official-installscript' for t in tasks))
            self.assertFalse((p/'sentinel').exists())

    def test_malformed_or_missing_component_does_not_become_satisfied(self):
        with tempfile.TemporaryDirectory() as d:
            (Path(d)/'broken.vdf').write_text('"InstallScript" { "Run Process" {')
            self.assertEqual(inspect_scripts(d,'99')[0],[])
            self.assertEqual(inspect_scripts(d,'99')[1][0]['kind'],'official-installscript')
        with self.assertRaises(ValueError):vdf('"A" {')

    def test_bundled_unity_or_optional_plugins_never_select_an_api(self):
        for files in ({'UnityPlayer.dll':5},{'D3D12.dll':5,'NNEPlugin.dll':3},{'d3d11.dll':2,'d3d12.dll':2}):
            self.assertEqual(detect_renderer(files,[],'550'),('auto','unknown'))
        self.assertEqual(detect_renderer({},['-d3d12'],'10')[0],'d3dmetal')
        self.assertEqual(detect_renderer({},['-force-d3d11'],'10')[0],'dxmt')

    def test_minimum_requirements_are_candidates_not_selected_apis(self):
        for api,candidate in [('9.0c','auto'),('10','dxmt'),('11.3','dxmt'),('12','d3dmetal')]:
            row=profile({'pc_requirements':{'minimum':f'<li><strong>DirectX:</strong> Version {api}</li>'}})
            self.assertEqual(row['rendererCandidate'],candidate)
            self.assertNotIn('renderer',row)
        self.assertEqual(profile({'pc_requirements':{'minimum':'Windows 11, RAM 12 GB'}})['graphicsAPI'],'unknown')


if __name__=='__main__':unittest.main()
