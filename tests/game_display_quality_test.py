import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

spec=importlib.util.spec_from_file_location('quality',Path(__file__).resolve().parents[1]/'scripts/game_display_quality.py')
q=importlib.util.module_from_spec(spec);spec.loader.exec_module(q)

class QualityTests(unittest.TestCase):
    def fixture(self,root):
        root=root.resolve()
        prefix=root/'prefix';prefix.mkdir()
        reg=prefix/'user.reg';reg.write_text('[Software\\\\Wine\\\\Mac Driver] 1\n#time=1\n"RetinaMode"="N"\n"CaptureDisplaysForFullscreen"="N"\n\n[PrivateAccount] 1\n"fixtureSecret"="unchanged"\n')
        config=prefix/'GameUserSettings.ini';config.write_text('[ScalabilityGroups]\nsg.ResolutionQuality=100.000000\nsg.TextureQuality=2\nsg.ShadowQuality=1\n\n[/Script/Engine.GameUserSettings]\nResolutionSizeX=1728\nResolutionSizeY=1117\nbUseHDRDisplayOutput=True\n\n')
        return prefix,reg,config,root/'journal.json'
    def environment(self):
        return {'PLAYMELT_DISPLAY_POLICY':'external-windowed-v1','PLAYMELT_DISPLAY_SCALE':'2','PLAYMELT_DISPLAY_DESKTOP_WIDTH':'1728','PLAYMELT_DISPLAY_DESKTOP_HEIGHT':'1117','PLAYMELT_DISPLAY_PIXEL_WIDTH':'3456','PLAYMELT_DISPLAY_PIXEL_HEIGHT':'2234','PLAYMELT_GAME_X':'16','PLAYMELT_GAME_Y':'40'}
    def test_retina_pixels_and_window_coordinates_are_separate_from_logical_size(self):
        p=q.dimensions(self.environment());self.assertEqual(p['window'],[3456,2234,32,80]);self.assertEqual((p['width'],p['height']),(3456,2234))
    def test_unscaled_hdmi_does_not_double_output(self):
        e=self.environment();e.update(PLAYMELT_DISPLAY_SCALE='1',PLAYMELT_DISPLAY_DESKTOP_WIDTH='2560',PLAYMELT_DISPLAY_DESKTOP_HEIGHT='1440',PLAYMELT_DISPLAY_PIXEL_WIDTH='2560',PLAYMELT_DISPLAY_PIXEL_HEIGHT='1440')
        self.assertEqual(q.dimensions(e)['window'],[2560,1440,16,40])
    def test_unverified_or_inconsistent_geometry_is_refused(self):
        for field,value in [('PLAYMELT_DISPLAY_POLICY',''),('PLAYMELT_DISPLAY_SCALE','3'),('PLAYMELT_DISPLAY_PIXEL_WIDTH','3840'),('PLAYMELT_DISPLAY_PIXEL_HEIGHT','999999')]:
            e=self.environment();e[field]=value
            with self.assertRaises(ValueError):q.dimensions(e)
    def test_native_ffvii_prefs_preserve_hdr_shadows_and_account_values(self):
        with tempfile.TemporaryDirectory() as td:
            prefix,reg,config,journal=self.fixture(Path(td));q.prepare(prefix,config,q.dimensions(self.environment()),journal)
            self.assertIn('"RetinaMode"="Y"',reg.read_text());self.assertIn('"fixtureSecret"="unchanged"',reg.read_text())
            text=config.read_text();self.assertIn('ResolutionSizeX=3456',text);self.assertIn('ResolutionSizeY=2234',text);self.assertIn('sg.TextureQuality=3',text)
            self.assertIn('bUseHDRDisplayOutput=True',text);self.assertIn('sg.ShadowQuality=1',text)
            receipt=json.loads(journal.read_text());self.assertEqual(receipt['state'],'committed');self.assertFalse(receipt['globalModesChanged']);self.assertNotIn('fixtureSecret',journal.read_text())
    def test_other_games_do_not_receive_ffvii_ini_values(self):
        with tempfile.TemporaryDirectory() as td:
            prefix,reg,config,journal=self.fixture(Path(td));before=config.read_bytes();q.prepare(prefix,None,q.dimensions(self.environment()),journal)
            self.assertEqual(config.read_bytes(),before)
    def test_no_change_does_not_require_stopping_existing_windows_apps(self):
        with tempfile.TemporaryDirectory() as td:
            prefix,reg,config,journal=self.fixture(Path(td));plan=q.dimensions(self.environment());q.prepare(prefix,config,plan,journal);before=journal.read_bytes()
            idle=mock.Mock(side_effect=ValueError('busy'));q.prepare(prefix,config,plan,journal,idle);idle.assert_not_called();self.assertEqual(journal.read_bytes(),before)
    def test_busy_prefix_refuses_any_preference_change(self):
        with tempfile.TemporaryDirectory() as td:
            prefix,reg,config,journal=self.fixture(Path(td));before=(reg.read_bytes(),config.read_bytes())
            with self.assertRaises(ValueError):q.prepare(prefix,config,q.dimensions(self.environment()),journal,lambda:(_ for _ in ()).throw(ValueError('busy')))
            self.assertEqual((reg.read_bytes(),config.read_bytes()),before);self.assertFalse(journal.exists())
    def test_subsequent_in_game_resolution_choice_is_preserved(self):
        with tempfile.TemporaryDirectory() as td:
            prefix,reg,config,journal=self.fixture(Path(td));plan=q.dimensions(self.environment());q.prepare(prefix,config,plan,journal)
            config.write_text(config.read_text().replace('ResolutionSizeX=3456','ResolutionSizeX=1920'))
            before=config.read_bytes();q.prepare(prefix,config,plan,journal)
            self.assertEqual(config.read_bytes(),before)
    def test_incomplete_transaction_is_never_overwritten(self):
        with tempfile.TemporaryDirectory() as td:
            prefix,reg,config,journal=self.fixture(Path(td));journal.write_text('{"state":"prepared"}');before=reg.read_bytes()
            with self.assertRaises(ValueError):q.prepare(prefix,config,q.dimensions(self.environment()),journal)
            self.assertEqual(reg.read_bytes(),before)
    def test_second_file_failure_rolls_back_first_without_touching_other_data(self):
        with tempfile.TemporaryDirectory() as td:
            prefix,reg,config,journal=self.fixture(Path(td));before=(reg.read_bytes(),config.read_bytes());real=q.atomic
            def failing(path,data):
                if path==config:raise OSError('fixture failure')
                real(path,data)
            with mock.patch.object(q,'atomic',side_effect=failing),self.assertRaises(OSError):q.prepare(prefix,config,q.dimensions(self.environment()),journal)
            self.assertEqual((reg.read_bytes(),config.read_bytes()),before);self.assertEqual(json.loads(journal.read_text())['state'],'rolled-back')
    def test_symlink_target_is_refused(self):
        with tempfile.TemporaryDirectory() as td:
            prefix,reg,config,journal=self.fixture(Path(td));link=prefix/'linked.ini';link.symlink_to(config)
            with self.assertRaises(ValueError):q.prepare(prefix,link,q.dimensions(self.environment()),journal)

if __name__=='__main__':unittest.main()
