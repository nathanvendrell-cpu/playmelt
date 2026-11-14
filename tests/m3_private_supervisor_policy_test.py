import importlib.util
import sys
import unittest
from pathlib import Path

module_path = Path(__file__).resolve().parents[1] / 'scripts/m3_private_supervisor_policy.py'
spec = importlib.util.spec_from_file_location('m3_private_supervisor_policy', module_path)
policy = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = policy
spec.loader.exec_module(policy)

class PolicyTests(unittest.TestCase):
    def setUp(self):
        self.run_id = 'b6084a91-460f-4cb7-93f8-126e3d5a2b7f'
        self.products = '/tmp/Products.noindex'
        root = self.products + '/m3-wine-' + self.run_id + '-fixture'
        self.scope = policy.PrivateScope(self.run_id, 501, root, root + '/prefix', '/engine')

    def test_private_prefix_and_canonical_renderer(self):
        self.scope.validate(self.products)
        env = self.scope.environment({'WINEPREFIX':'/standard/prefix','CX_D3DMETALPATH':'/payload/external','WINEDLLPATH_PREPEND':'/payload/wine'})
        self.assertEqual(env['WINEPREFIX'], self.scope.prefix)
        self.assertEqual(env['CX_D3DMETALPATH'], '/payload/external')
        self.assertEqual(env['PLAYMELT_TEST_RUN'], self.run_id)
        self.assertEqual(env['ROSETTA_ADVERTISE_AVX'], '1')

    def test_non_private_paths_are_refused(self):
        bad = policy.PrivateScope(self.run_id, 501, self.scope.root, '/standard/prefix', '/engine')
        with self.assertRaises(ValueError): bad.validate(self.products)
        bad = policy.PrivateScope(self.run_id, 501, self.scope.root + '/../other', self.scope.prefix, '/engine')
        with self.assertRaises(ValueError): bad.validate(self.products)

    def test_shutdown_is_limited_to_selected_server(self):
        self.assertEqual(self.scope.shutdown_commands('/engine/bin/wineserver'), (('/engine/bin/wineserver','-k'),('/engine/bin/wineserver','-w')))
        with self.assertRaises(ValueError): self.scope.shutdown_commands('/elsewhere/wineserver')

    def test_pid_reuse_uid_and_executable_changes_refused(self):
        p = policy.ProcessIdentity(10, 501, 100, 123, '/engine/bin/wineserver')
        self.assertTrue(policy.safe_identity_match(p,p))
        for q in [policy.ProcessIdentity(10,501,101,123,p.executable),policy.ProcessIdentity(10,502,100,123,p.executable),policy.ProcessIdentity(10,501,100,123,'/other')]:
            self.assertFalse(policy.safe_identity_match(p,q))

if __name__ == '__main__': unittest.main()
