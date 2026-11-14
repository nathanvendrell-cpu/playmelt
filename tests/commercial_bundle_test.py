import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
import subprocess
import zipfile
import base64
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec); spec.loader.exec_module(value)
    return value
VERIFY = module('bundle_verifier', ROOT / 'scripts/verify_commercial_bundle.py')
CONFIG = module('bundle_config', ROOT / 'scripts/configure_account_bundle.py')

class CommercialBundleTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='playmelt-distribution-fixture-')
        self.addCleanup(self.tmp.cleanup)
        self.bundle = Path(self.tmp.name) / 'Playmelt.app'
        resources = self.bundle / 'Contents/Resources'
        (resources / 'ThirdPartyLicenses').mkdir(parents=True)
        for name in ['GCC-COPYING3.txt', 'GCC-Runtime-Exception.txt', 'MinGW-w64-COPYING.txt']:
            (resources / 'ThirdPartyLicenses' / name).write_text('test fixture')
        (resources / 'ThirdPartyNotices.txt').write_text('test fixture')
        binary = self.bundle / 'Contents/MacOS/MetalMax'; binary.parent.mkdir(); binary.write_bytes(b'test fixture, never executable')
        self.config = ROOT / 'config/native-account.json'
        self.base = {'CFBundleIdentifier':'com.robtech.metalmaxgaminghub','CFBundleVersion':'18','CFBundleShortVersionString':'2.2.0'}
        # Explicit synthetic layout, not a working interpreter or a provenance proof.
        self.python=self.bundle/'Contents/Resources/Python'
        paths=['bin/python3','bin/legendary','lib/python3.13/encodings/__init__.py',
               'lib/python3.13/json/__init__.py','lib/python3.13/ssl.py','lib/python3.13/hashlib.py',
               'lib/python3.13/urllib/__init__.py','lib/python3.13/importlib/__init__.py',
               'lib/python3.13/lib-dynload/_ssl.cpython-313-darwin.so',
               'lib/python3.13/site-packages/certifi/__init__.py','lib/python3.13/site-packages/certifi/cacert.pem',
               'lib/python3.13/site-packages/legendary/__init__.py',
               'lib/python3.13/site-packages/legendary_gl-0.21.1.dist-info/METADATA']
        self.python_files=[self.python/name for name in paths]
        for file in self.python_files:
            file.parent.mkdir(parents=True,exist_ok=True);file.write_bytes(b'fixture; not executable code')
        for file in self.python_files[:2]:file.chmod(0o755)
    def inspect(self, values):
        (self.bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps(dict(self.base, **values)))
        with patch.object(VERIFY, 'run', return_value=(0, 'Authority=Developer ID Application: FIXTURE\nTeamIdentifier=FIXTURE')):
            return VERIFY.inspect(self.bundle, '2.2.0', '18', self.config)
    def test_internal_owner_build_is_not_a_commercial_artifact_even_with_valid_signature_metadata(self):
        flags = CONFIG.configuration(self.config, False, {}, owner=True)
        result = self.inspect(flags)
        self.assertFalse(result['clientPackageIntegrityPassed']); self.assertEqual(result['failedGates'], ['internalBuildAbsent'])
    def test_qualified_release_metadata_is_distinct_from_owner_and_development(self):
        flags = CONFIG.configuration(self.config, True, {'PLAYMELT_ACCOUNT_VERIFIED':'1'})
        self.assertTrue(self.inspect(flags)['clientPackageIntegrityPassed'])
        flags['PlaymeltInternalBuild'] = True
        self.assertFalse(self.inspect(flags)['clientPackageIntegrityPassed'])
    def test_development_bypass_cannot_pass_distribution_gate(self):
        result = self.inspect(CONFIG.configuration(self.config, False, {}))
        self.assertIn('commercialEnforcement', result['failedGates']); self.assertIn('developmentBypassAbsent', result['failedGates'])
    def test_ad_hoc_integrity_is_distinct_from_platform_trust_and_update_readiness(self):
        values=CONFIG.configuration(self.config,True,{'PLAYMELT_ACCOUNT_VERIFIED':'1'})
        (self.bundle/'Contents/Info.plist').write_bytes(plistlib.dumps(dict(self.base,**values)))
        def codesign_only(command):return (0,'Signature=adhoc\nTeamIdentifier=not set')if command[0]=='/usr/bin/codesign'else(1,'')
        with patch.object(VERIFY,'run',side_effect=codesign_only):result=VERIFY.inspect(self.bundle,'2.2.0','18',self.config)
        self.assertTrue(result['clientPackageIntegrityPassed']);self.assertFalse(result['platformTrust']['passed']);self.assertFalse(result['signedUpdateArtifactReady']);self.assertNotIn('passed',result)
        self.assertEqual(result['clientCredentialChannel'],{'selection':'data-protection-keychain','explicit':False,'configurationValid':True,'runtimePersistenceVerified':False})
    def test_explicit_ad_hoc_client_channel_is_visible_without_claiming_platform_trust(self):
        values=CONFIG.configuration(self.config,True,{'PLAYMELT_ACCOUNT_VERIFIED':'1','PLAYMELT_CLIENT_CREDENTIAL_CHANNEL':'adhoc-login-v1'})
        (self.bundle/'Contents/Info.plist').write_bytes(plistlib.dumps(dict(self.base,**values)))
        def codesign_only(command):return (0,'Signature=adhoc\nTeamIdentifier=not set')if command[0]=='/usr/bin/codesign'else(1,'')
        with patch.object(VERIFY,'run',side_effect=codesign_only):result=VERIFY.inspect(self.bundle,'2.2.0','18',self.config)
        self.assertTrue(result['clientPackageIntegrityPassed']);self.assertTrue(result['gates']['clientCredentialChannelAllowed'])
        self.assertEqual(result['clientCredentialChannel'],{'selection':'adhoc-login-v1','explicit':True,'configurationValid':True,'runtimePersistenceVerified':False})
        self.assertFalse(result['platformTrust']['passed']);self.assertFalse(result['platformTrust']['gates']['developerIDSignature'])
    def test_unknown_or_owner_development_credential_channels_fail_preflight(self):
        values=CONFIG.configuration(self.config,True,{'PLAYMELT_ACCOUNT_VERIFIED':'1'})
        for change in [{'PlaymeltClientCredentialChannel':''},{'PlaymeltClientCredentialChannel':'unknown'},{'PlaymeltClientCredentialChannel':'adhoc-login-v1','PlaymeltInternalBuild':True},{'PlaymeltClientCredentialChannel':'adhoc-login-v1','PlaymeltDevelopmentBuild':True},{'PlaymeltClientCredentialChannel':'adhoc-login-v1','PlaymeltCommercialAccessEnabled':False}]:
            result=self.inspect(dict(values,**change))
            self.assertFalse(result['clientPackageIntegrityPassed']);self.assertFalse(result['gates']['clientCredentialChannelAllowed']);self.assertFalse(result['clientCredentialChannel']['configurationValid'])
    def test_python_resources_presence_is_required_without_claiming_fresh_mac_runtime(self):
        values=CONFIG.configuration(self.config,True,{'PLAYMELT_ACCOUNT_VERIFIED':'1'})
        result=self.inspect(values)
        self.assertTrue(result['gates']['portablePythonResourcesPresent']);self.assertFalse(result['runtimeFreshMacVerified'])
        self.python.rename(self.python.with_name('Python.fixture-absent'))
        result=self.inspect(values)
        self.assertFalse(result['clientPackageIntegrityPassed']);self.assertIn('portablePythonResourcesPresent',result['failedGates']);self.assertFalse(result['runtimeFreshMacVerified'])
    def test_each_python_resource_and_executable_permission_is_required(self):
        for file in self.python_files:
            missing=file.with_name(file.name+'.fixture-absent');file.rename(missing)
            try:self.assertFalse(VERIFY.portable_python_resources_present(self.bundle),str(file.relative_to(self.python)))
            finally:missing.rename(file)
        for file in self.python_files[:2]:
            file.chmod(0o644)
            try:self.assertFalse(VERIFY.portable_python_resources_present(self.bundle))
            finally:file.chmod(0o755)
    def test_python_internal_links_are_allowed_and_external_or_broken_links_refused(self):
        executable=self.python/'bin/python3';target=executable.with_name('python3.13');executable.rename(target);executable.symlink_to(target.name)
        self.assertTrue(VERIFY.portable_python_resources_present(self.bundle))
        outside=Path(self.tmp.name)/'outside-python';outside.write_bytes(b'fixture');outside.chmod(0o755)
        executable.unlink();executable.symlink_to(outside)
        self.assertFalse(VERIFY.portable_python_resources_present(self.bundle))
        executable.unlink();executable.symlink_to(target.name)
        unused=self.python/'external-unused-link';unused.symlink_to(outside)
        self.assertFalse(VERIFY.portable_python_resources_present(self.bundle))
        unused.unlink();unused.symlink_to('missing-fixture')
        self.assertFalse(VERIFY.portable_python_resources_present(self.bundle))
    def test_python_root_cannot_point_outside_the_client_bundle(self):
        outside=Path(self.tmp.name)/'outside-python-tree';self.python.rename(outside);self.python.symlink_to(outside,target_is_directory=True)
        self.assertFalse(VERIFY.portable_python_resources_present(self.bundle))
    def test_standalone_python_builtin_ssl_is_checked_statically_without_execution(self):
        extension=self.python/'lib/python3.13/lib-dynload/_ssl.cpython-313-darwin.so';extension.rename(extension.with_suffix('.fixture-absent'))
        with patch.object(VERIFY,'run',return_value=(0,'000000010098fb88 T _PyInit__ssl\n'))as probe:
            self.assertTrue(VERIFY.portable_python_resources_present(self.bundle))
            self.assertEqual(probe.call_args.args[0],['/usr/bin/nm','-gU',str((self.python/'bin/python3').resolve())])
            self.assertTrue(VERIFY.portable_python_layout_present(self.python,self.python))
        for code,symbols in [(1,'000000010098fb88 T _PyInit__ssl\n'),(0,'000000010098fb88 T _PyInit__ssl_other\n'),(0,'unverified text mentions _PyInit__ssl')]:
            with patch.object(VERIFY,'run',return_value=(code,symbols)):
                self.assertFalse(VERIFY.portable_python_resources_present(self.bundle))
    def test_update_requires_real_signature_exact_archive_and_monotone_build(self):
        env={'PLAYMELT_ACCOUNT_VERIFIED':'1','PLAYMELT_UPDATES_READY':'1','PLAYMELT_UPDATE_FEED_URL':'https://7agency.fr/Playmelt/compte/v1/updates/appcast.xml','PLAYMELT_UPDATE_PUBLIC_KEY':base64.b64encode(bytes(range(32))).decode()}
        values=CONFIG.configuration(self.config,True,env)
        archive=Path(self.tmp.name)/'update.zip';payload=b'fixed test message'
        # A deterministic TEST key exists only in this isolated signing process.
        raw=Path(self.tmp.name)/'message';raw.write_bytes(payload)
        code='import Foundation;import CryptoKit;let k=try Curve25519.Signing.PrivateKey(rawRepresentation:Data(repeating:17,count:32));let d=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]));print(k.publicKey.rawRepresentation.base64EncodedString());print(try k.signature(for:d).base64EncodedString())'
        def sign(path):
            with tempfile.TemporaryDirectory(prefix='playmelt-test-signature-')as cache:
                result=subprocess.run(['/usr/bin/swift','-module-cache-path',cache+'/cache','-e',code,str(path)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=90,check=True)
            return result.stdout.decode().strip().splitlines()
        public,_=sign(raw);values['SUPublicEDKey']=public
        (self.bundle/'Contents/Info.plist').write_bytes(plistlib.dumps(dict(self.base,**values)))
        with zipfile.ZipFile(archive,'w')as z:
            for file in self.bundle.rglob('*'):
                if file.is_file():z.write(file,str(file.relative_to(self.bundle.parent)))
        _,signature=sign(archive)
        self.assertTrue(VERIFY.verify_update_signature(archive,public,signature))
        with patch.object(VERIFY,'run',return_value=(0,'Signature=adhoc\nTeamIdentifier=not set')):
            report=VERIFY.inspect(self.bundle,'2.2.0','18',self.config,archive,signature,'17',public)
        self.assertTrue(report['signedUpdateArtifactReady']);self.assertTrue(report['updates']['archiveMatchesInspectedBundle']);self.assertFalse(report['platformTrust']['passed']);self.assertFalse(report['authenticatedTransportRuntimeVerified'])
        with patch.object(VERIFY,'run',return_value=(0,'Signature=adhoc\nTeamIdentifier=not set')):
            wrong_approval=VERIFY.inspect(self.bundle,'2.2.0','18',self.config,archive,signature,'17',base64.b64encode(bytes(range(32))).decode())
        self.assertFalse(wrong_approval['signedUpdateArtifactReady']);self.assertFalse(wrong_approval['gates']['expectedUpdatePublicKey'])
        self.assertFalse(VERIFY.newer_build('18','18'));self.assertFalse(VERIFY.newer_build('17','18'));self.assertFalse(VERIFY.newer_build('18.0','18'));self.assertFalse(VERIFY.newer_build('18.1','18'));self.assertFalse(VERIFY.newer_build('018','17'));self.assertTrue(VERIFY.newer_build('19','18'))
        (self.bundle/'Contents/MacOS/MetalMax').write_bytes(b'changed after archive')
        self.assertFalse(VERIFY.archive_matches_bundle(archive,self.bundle))
        raw.write_bytes(b'unsigned changed bytes');self.assertFalse(VERIFY.verify_update_signature(raw,public,signature))
    def test_zip_traversal_and_duplicate_or_foreign_bundle_are_refused(self):
        for names in [['../outside'],['Other.app/Contents/Info.plist'],['Playmelt.app/a','Playmelt.app/a']]:
            archive=Path(self.tmp.name)/'unsafe.zip'
            with zipfile.ZipFile(archive,'w')as z:
                for name in names:z.writestr(name,b'fixture')
            self.assertFalse(VERIFY.archive_matches_bundle(archive,self.bundle))
    def test_preflight_never_accepts_public_or_secret_query_feed(self):
        flags=CONFIG.configuration(self.config,True,{'PLAYMELT_ACCOUNT_VERIFIED':'1'})
        for feed in ['https://7agency.fr/Playmelt/appcast.xml','https://7agency.fr/Playmelt/compte/v1/updates/appcast.xml?token=never']:
            flags.update({'PlaymeltAutomaticUpdatesAvailable':True,'PlaymeltUpdatesRequireAuthentication':True,'SUFeedURL':feed,'SUPublicEDKey':base64.b64encode(bytes(range(32))).decode(),'SUEnableAutomaticChecks':True,'SUAllowsAutomaticUpdates':True,'SUAutomaticallyUpdate':True})
            result=self.inspect(flags);self.assertFalse(result['clientPackageIntegrityPassed']);self.assertFalse(result['signedUpdateArtifactReady']);self.assertIn('updatePolicyConsistent',result['failedGates'])

if __name__ == '__main__': unittest.main()
