import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import plistlib
import base64
from unittest import mock

spec=importlib.util.spec_from_file_location('bundle_config',Path(__file__).resolve().parents[1]/'scripts/configure_account_bundle.py');config=importlib.util.module_from_spec(spec);spec.loader.exec_module(config)
class BundleConfigurationTests(unittest.TestCase):
    def test_owner_build_enforces_access_without_claiming_commercial_qualification(self):
        public=Path(__file__).resolve().parents[1]/'config/native-account.json'
        value=config.configuration(public,False,{'PLAYMELT_ACCOUNT_VERIFIED':'0'},owner=True)
        self.assertTrue(value['PlaymeltCommercialAccessEnabled']);self.assertFalse(value['PlaymeltDevelopmentBuild']);self.assertTrue(value['PlaymeltInternalBuild'])
        self.assertFalse(value['PlaymeltAutomaticUpdatesAvailable'])
        with self.assertRaises(ValueError):config.configuration(public,True,{},owner=True)
        with self.assertRaises(ValueError):config.configuration(public,False,{'PLAYMELT_ACCOUNT_SERVICE_READY':'0','PLAYMELT_PASSWORD_LOGIN_READY':'0','PLAYMELT_GOOGLE_LOGIN_READY':'0'},owner=True)
    def test_owner_metadata_removes_development_source_path_and_never_changes_version(self):
        public=Path(__file__).resolve().parents[1]/'config/native-account.json'
        with tempfile.TemporaryDirectory() as tmp,mock.patch.dict(config.os.environ,{},clear=True):
            path=Path(tmp)/'Info.plist';path.write_bytes(plistlib.dumps({'MetalMaxSourceDirectory':'/private/source','CFBundleVersion':'18','SUPublicEDKey':'unchanged'}))
            config.main(['configure','--write',str(public),'owner',str(path)])
            info=plistlib.loads(path.read_bytes());self.assertNotIn('MetalMaxSourceDirectory',info);self.assertEqual(info['CFBundleVersion'],'18');self.assertEqual(info['SUPublicEDKey'],'unchanged');self.assertTrue(info['PlaymeltInternalBuild'])
    def test_unknown_configuration_modes_fail_before_mutation(self):
        with self.assertRaises(ValueError):config.main(['configure','--check','unused','unverified'])
    def test_automatic_updates_stay_off_until_authenticated_transport_exists(self):
        public=Path(__file__).resolve().parents[1]/'config/native-account.json'
        for release,env in [(False,{}),(True,{'PLAYMELT_ACCOUNT_VERIFIED':'1','PLAYMELT_PASSWORD_LOGIN_READY':'1'})]:
            value=config.configuration(public,release,env)
            for field in ['PlaymeltAutomaticUpdatesAvailable','SUEnableAutomaticChecks','SUAllowsAutomaticUpdates','SUAutomaticallyUpdate']:self.assertFalse(value[field])
    def test_google_is_gated_separately_and_cannot_override_a_missing_service(self):
        public=Path(__file__).resolve().parents[1]/'config/native-account.json'
        self.assertTrue(json.loads(public.read_text())['googleLoginReady'])
        self.assertTrue(config.configuration(public,False,{})['PlaymeltGoogleLoginAvailable'])
        self.assertFalse(config.configuration(public,False,{'PLAYMELT_GOOGLE_LOGIN_READY':'0'})['PlaymeltGoogleLoginAvailable'])
        self.assertTrue(config.configuration(public,False,{'PLAYMELT_GOOGLE_LOGIN_READY':'1'})['PlaymeltGoogleLoginAvailable'])
        for env in [{'PLAYMELT_GOOGLE_LOGIN_READY':'yes'},{'PLAYMELT_GOOGLE_LOGIN_READY':'1','PLAYMELT_ACCOUNT_SERVICE_READY':'0','PLAYMELT_PASSWORD_LOGIN_READY':'0'}]:
            with self.assertRaises(ValueError):config.configuration(public,False,env)
    def test_development_can_connect_to_configured_service_without_activating_commercial_gate(self):
        public=Path(__file__).resolve().parents[1]/'config/native-account.json';value=config.configuration(public,False,{})
        self.assertFalse(value['PlaymeltCommercialAccessEnabled']);self.assertEqual(value['PlaymeltAccountServiceAvailable'],json.loads(public.read_text())['serviceReady']);self.assertTrue(value['PlaymeltDevelopmentBuild'])
        self.assertEqual(value['PlaymeltAccountURL'],'https://7agency.fr/Playmelt/compte');self.assertEqual(len(config.base64.b64decode(value['PlaymeltLicensePublicKey'])),32)
    def test_release_requires_both_hosted_readiness_and_explicit_verification(self):
        public=Path(__file__).resolve().parents[1]/'config/native-account.json'
        for env in [{},{'PLAYMELT_ACCOUNT_SERVICE_READY':'1'},{'PLAYMELT_ACCOUNT_SERVICE_READY':'0','PLAYMELT_ACCOUNT_VERIFIED':'1'}]:
            with self.assertRaises(ValueError):config.configuration(public,True,env)
        value=config.configuration(public,True,{'PLAYMELT_ACCOUNT_SERVICE_READY':'1','PLAYMELT_ACCOUNT_VERIFIED':'1','PLAYMELT_PASSWORD_LOGIN_READY':'1'})
        self.assertTrue(value['PlaymeltCommercialAccessEnabled']);self.assertTrue(value['PlaymeltAccountServiceAvailable']);self.assertFalse(value['PlaymeltDevelopmentBuild'])
    def test_account_verification_does_not_accept_the_old_commercial_signal(self):
        public=Path(__file__).resolve().parents[1]/'config/native-account.json'
        base={'PLAYMELT_ACCOUNT_SERVICE_READY':'1','PLAYMELT_PASSWORD_LOGIN_READY':'1'}
        with self.assertRaisesRegex(ValueError,'account/device verification'):
            config.configuration(public,True,dict(base,PLAYMELT_COMMERCIAL_VERIFIED='1'))
        value=config.configuration(public,True,dict(base,PLAYMELT_ACCOUNT_VERIFIED='1'))
        self.assertTrue(value['PlaymeltCommercialAccessEnabled'])
        self.assertFalse(value['PlaymeltDevelopmentBuild'])
        self.assertFalse(value['PlaymeltAutomaticUpdatesAvailable'])
    def test_ad_hoc_client_channel_requires_an_explicit_qualified_release(self):
        public=Path(__file__).resolve().parents[1]/'config/native-account.json'
        env={'PLAYMELT_ACCOUNT_VERIFIED':'1','PLAYMELT_CLIENT_CREDENTIAL_CHANNEL':'adhoc-login-v1'}
        value=config.configuration(public,True,env)
        self.assertEqual(value['PlaymeltClientCredentialChannel'],'adhoc-login-v1')
        self.assertTrue(value['PlaymeltCommercialAccessEnabled'])
        self.assertFalse(value['PlaymeltDevelopmentBuild']);self.assertFalse(value['PlaymeltInternalBuild'])
        for release,owner in [(False,False),(False,True),(True,True)]:
            with self.assertRaises(ValueError):config.configuration(public,release,env,owner=owner)
        with self.assertRaises(ValueError):config.configuration(public,True,{'PLAYMELT_CLIENT_CREDENTIAL_CHANNEL':'adhoc-login-v1'})
        for unknown in ['', 'data-protection-keychain', 'adhoc-login-v2', True]:
            with self.assertRaises(ValueError):config.configuration(public,True,dict(env,PLAYMELT_CLIENT_CREDENTIAL_CHANNEL=unknown))
    def test_absent_channel_keeps_data_protection_and_clears_a_stale_explicit_choice(self):
        public=Path(__file__).resolve().parents[1]/'config/native-account.json'
        for release,owner,env in [(False,False,{}),(False,True,{}),(True,False,{'PLAYMELT_ACCOUNT_VERIFIED':'1'})]:
            self.assertNotIn('PlaymeltClientCredentialChannel',config.configuration(public,release,env,owner=owner))
        with tempfile.TemporaryDirectory()as tmp,mock.patch.dict(config.os.environ,{'PLAYMELT_ACCOUNT_VERIFIED':'1'},clear=True):
            path=Path(tmp)/'Info.plist';path.write_bytes(plistlib.dumps({'PlaymeltClientCredentialChannel':'adhoc-login-v1','CFBundleVersion':'30'}))
            config.main(['configure','--write',str(public),'1',str(path)])
            info=plistlib.loads(path.read_bytes());self.assertNotIn('PlaymeltClientCredentialChannel',info);self.assertEqual(info['CFBundleVersion'],'30')
            before=path.read_bytes()
            with mock.patch.dict(config.os.environ,{'PLAYMELT_CLIENT_CREDENTIAL_CHANNEL':'unknown'}):
                with self.assertRaises(ValueError):config.main(['configure','--write',str(public),'1',str(path)])
            self.assertEqual(path.read_bytes(),before)
    def test_bad_url_or_public_key_cannot_enter_the_bundle(self):
        public=Path(__file__).resolve().parents[1]/'config/native-account.json'
        for env in [{'PLAYMELT_ACCOUNT_URL':'http://example.test'},{'PLAYMELT_ACCOUNT_URL':'https://user:secret@example.test'},{'PLAYMELT_LICENSE_PUBLIC_KEY':'not-a-key'},{'PLAYMELT_ACCOUNT_SERVICE_READY':'yes'}]:
            with self.assertRaises(ValueError):config.configuration(public,False,env)
    def test_password_flow_is_independently_gated_until_hosted_verification(self):
        public=Path(__file__).resolve().parents[1]/'config/native-account.json'
        self.assertEqual(config.configuration(public,False,{})['PlaymeltPasswordLoginAvailable'],json.loads(public.read_text())['passwordLoginReady'])
        self.assertFalse(config.configuration(public,False,{'PLAYMELT_PASSWORD_LOGIN_READY':'0'})['PlaymeltPasswordLoginAvailable'])
        for env in [{'PLAYMELT_PASSWORD_LOGIN_READY':'yes'},{'PLAYMELT_PASSWORD_LOGIN_READY':'1','PLAYMELT_ACCOUNT_SERVICE_READY':'0'}]:
            with self.assertRaises(ValueError):config.configuration(public,False,env)
        with self.assertRaises(ValueError):config.configuration(public,True,{'PLAYMELT_ACCOUNT_VERIFIED':'1','PLAYMELT_PASSWORD_LOGIN_READY':'0'})
    def test_writing_account_configuration_preserves_updater_key_and_refuses_unverified_activation(self):
        public=Path(__file__).resolve().parents[1]/'config/native-account.json'
        with tempfile.TemporaryDirectory() as tmp,mock.patch.dict(config.os.environ,{},clear=True):
            path=Path(tmp)/'Info.plist';path.write_bytes(plistlib.dumps({'SUPublicEDKey':'separate-sparkle-key','CFBundleShortVersionString':'2.2.0'}))
            config.main(['configure','--write',str(public),'0',str(path)])
            value=plistlib.loads(path.read_bytes());self.assertEqual(value['SUPublicEDKey'],'separate-sparkle-key');self.assertFalse(value['PlaymeltCommercialAccessEnabled'])
            before=path.read_bytes()
            with self.assertRaises(ValueError):config.main(['configure','--write',str(public),'1',str(path)])
            self.assertEqual(path.read_bytes(),before)
    def test_authenticated_update_configuration_is_explicit_and_fixed(self):
        public=Path(__file__).resolve().parents[1]/'config/native-account.json'
        env={'PLAYMELT_ACCOUNT_VERIFIED':'1','PLAYMELT_UPDATES_READY':'1','PLAYMELT_UPDATE_FEED_URL':'https://7agency.fr/Playmelt/compte/v1/updates/appcast.xml','PLAYMELT_UPDATE_PUBLIC_KEY':base64.b64encode(bytes(range(32))).decode()}
        value=config.configuration(public,True,env)
        for flag in ['PlaymeltAutomaticUpdatesAvailable','PlaymeltUpdatesRequireAuthentication','SUEnableAutomaticChecks','SUAllowsAutomaticUpdates','SUAutomaticallyUpdate']:self.assertTrue(value[flag])
        self.assertEqual(value['SUFeedURL'],env['PLAYMELT_UPDATE_FEED_URL']);self.assertEqual(value['SUPublicEDKey'],env['PLAYMELT_UPDATE_PUBLIC_KEY'])
        self.assertTrue(value['PlaymeltCommercialAccessEnabled']);self.assertFalse(value['PlaymeltDevelopmentBuild']);self.assertFalse(value['PlaymeltInternalBuild'])
        with self.assertRaises(ValueError):config.configuration(public,False,env)
    def test_unknown_missing_or_foreign_update_transport_cannot_be_enabled(self):
        public=Path(__file__).resolve().parents[1]/'config/native-account.json'
        base={'PLAYMELT_ACCOUNT_VERIFIED':'1','PLAYMELT_UPDATES_READY':'1','PLAYMELT_UPDATE_FEED_URL':'https://7agency.fr/Playmelt/compte/v1/updates/appcast.xml','PLAYMELT_UPDATE_PUBLIC_KEY':base64.b64encode(bytes(range(32))).decode()}
        for change in [{'PLAYMELT_UPDATES_READY':'yes'},{'PLAYMELT_UPDATE_FEED_URL':''},{'PLAYMELT_UPDATE_PUBLIC_KEY':''},{'PLAYMELT_UPDATE_PUBLIC_KEY':base64.b64encode(bytes(32)).decode()},{'PLAYMELT_UPDATE_FEED_URL':'https://7agency.fr/Playmelt/appcast.xml'},{'PLAYMELT_UPDATE_FEED_URL':'https://foreign.test/v1/updates/appcast.xml'},{'PLAYMELT_UPDATE_FEED_URL':base['PLAYMELT_UPDATE_FEED_URL']+'?token=never'},{'PLAYMELT_UPDATE_FEED_URL':base['PLAYMELT_UPDATE_FEED_URL']+'#token=never'}]:
            with self.assertRaises(ValueError):config.configuration(public,True,dict(base,**change))
    def test_disabled_updates_remove_the_old_public_feed_without_changing_key_or_version(self):
        public=Path(__file__).resolve().parents[1]/'config/native-account.json'
        with tempfile.TemporaryDirectory()as tmp,mock.patch.dict(config.os.environ,{},clear=True):
            path=Path(tmp)/'Info.plist';path.write_bytes(plistlib.dumps({'SUFeedURL':'https://7agency.fr/Playmelt/appcast.xml','SUPublicEDKey':'retained-public-key','CFBundleVersion':'29'}))
            config.main(['configure','--write',str(public),'owner',str(path)]);value=plistlib.loads(path.read_bytes())
            self.assertNotIn('SUFeedURL',value);self.assertEqual(value['SUPublicEDKey'],'retained-public-key');self.assertEqual(value['CFBundleVersion'],'29')

if __name__=='__main__':unittest.main()
