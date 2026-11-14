import contextlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

scripts=Path(__file__).resolve().parents[1]/'scripts';sys.path.insert(0,str(scripts))
spec=importlib.util.spec_from_file_location('m3_hardwareid_experiment',scripts/'m3_hardwareid_experiment.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)

class Harness:
    def __init__(self,root,overwrite=False,fail_game=False):
        self.root=root; self.value=m.tx.ORIGINAL; self.overwrite=overwrite; self.fail_game=fail_game; self.called=[]; self.environments=[]
        self.ident={'root_dev':1,'root_ino':2,'prefix_dev':1,'prefix_ino':3,'uid':501}
        self.plan={'wine':'/fixture/wine','server':'/fixture/wineserver','environment':{},'rendererHash':'renderer','engineFingerprint':'engine'}
    def probe(self,plan,folder,marker,stage,seen):
        self.environments.append(('probe',dict(plan['environment'])));self.called.append('probe-'+stage)
        if stage=='after' and self.overwrite: self.value=m.tx.ORIGINAL
        hw=m.tx.APPLE if self.value==m.tx.ORIGINAL else m.tx.AMD
        return {'schema':1,'kind':'playmelt-setupapi-display-probe','nonce':'nonce','setupComplete':True,'interfacesComplete':True,'setupDevices':[{'instanceId':m.INSTANCE,'hardwareId':hw}]},'nonce'
    def invoke(self,plan,mode,folder,marker,seen):
        self.environments.append(('helper',dict(plan['environment'])));self.called.append(mode)
        if mode=='--apply':
            self.assert_prepared(folder); self.value=m.tx.REPLACEMENT
        if mode=='--undo': self.value=m.tx.ORIGINAL
        return {'ok':True,'type':7,'hex':self.value}
    def assert_prepared(self,folder):
        journal=json.loads((folder/'journal.json').read_text())
        if journal['state']!='prepared' or journal['before_hex']!=m.tx.ORIGINAL: raise AssertionError('journal not durable before write')
    def shutdown(self,server,env,directory,state): self.environments.append(('shutdown',dict(env)));state['shutdown'].update({'-k':{'exit':0},'-w':{'exit':0}})
    def game(self,*args):
        self.environments.append(('game',dict(args[1])));self.called.append('game')
        if self.fail_game: raise RuntimeError('game failed')
        class Child:
            def poll(self): return 0
        return Child(),False,False

class ExperimentTests(unittest.TestCase):
    def test_noisy_json_strict_unique_and_nonce(self):
        probe={'schema':1,'kind':'playmelt-setupapi-display-probe','nonce':'n','setupDevices':[]}
        line=json.dumps(probe)
        self.assertEqual(m.tx.extract_record('[mvk-info] banner\n'+line+'\n',kind='setupapi',nonce='n'),probe)
        for raw in (line+'\n'+line, line+'\n{broken',line+'\n{"ok":true}', '{"schema":1,"schema":1}'):
            with self.assertRaises(RuntimeError):m.tx.extract_record(raw,kind='setupapi',nonce='n')
        with self.assertRaises(RuntimeError):m.tx.extract_record(line,kind='setupapi',nonce='wrong')
        with self.assertRaises(RuntimeError):m.tx.extract_record('{"schema":NaN}',kind='setupapi',nonce='n')

    def test_cas_json_strict_and_environment_matches_game(self):
        value={'ok':True,'type':7,'hex':'00ff'}
        self.assertEqual(m.tx.extract_record('banner\n'+json.dumps(value)+'\n',kind='cas'),value)
        for bad in ({'ok':1,'type':7,'hex':'00'},{'ok':True,'type':True,'hex':'00'},
                    {'ok':True,'type':7,'hex':'abc'},{'ok':True,'type':7,'hex':'zz'}):
            with self.assertRaises(RuntimeError):m.tx.extract_record(json.dumps(bad),kind='cas')
        plan={'environment':{'PATH':'/clean','WINEPREFIX':'/wrong','WINEDLLOVERRIDES':'wrong'}}
        env=m.tx.private_environment(plan,'mark')
        game=m.tx.private_environment(plan,'mark',debug='fixme-all,+msgbox,+dialog')
        for key,expected in {'WINEPREFIX':str(m.reuse.PREFIX),'WINEDLLOVERRIDES':'d3d12,d3d12core,dxgi=n,b;winemenubuilder.exe=d',
                             'ROSETTA_ADVERTISE_AVX':'1','MVK_CONFIG_LOG_LEVEL':'0','PATH':'/clean'}.items():
            self.assertEqual(env[key],expected);self.assertEqual(game[key],expected)
        self.assertEqual(plan['environment']['WINEDLLOVERRIDES'],'wrong')

    def test_probe_and_cas_preserve_raw_noisy_output(self):
        plan={'wine':'/wine','environment':{'PATH':'/clean'}}
        outputs=[]
        class Child:
            def poll(self): return 0
        def fake_run(argv,env,directory,log,timeout,inspector,marker,seen):
            if argv[-2]=='--nonce':
                record={'schema':1,'kind':'playmelt-setupapi-display-probe','nonce':argv[-1]}
            else: record={'ok':True,'type':7,'hex':'00ff'}
            raw='[mvk-info] fixture banner\n'+json.dumps(record)+'\n'
            log.write(raw.encode());outputs.append((env,Path(log.name),raw))
            return Child(),False,False
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            with mock.patch.object(m.base,'run_command',side_effect=fake_run),mock.patch.object(m.base,'reap_child'),mock.patch.object(m.base,'Inspector',return_value=None):
                response,nonce=m.probe(plan,root,'mark','before',{})
                result=m.tx.invoke(plan,'--read',root,'mark',{})
            self.assertEqual(response['nonce'],nonce);self.assertEqual(result['hex'],'00ff')
            for env,path,raw in outputs:
                self.assertEqual(path.read_text(),raw)
                self.assertEqual(env['WINEDLLOVERRIDES'],'d3d12,d3d12core,dxgi=n,b;winemenubuilder.exe=d')
                self.assertEqual(env['ROSETTA_ADVERTISE_AVX'],'1');self.assertEqual(env['MVK_CONFIG_LOG_LEVEL'],'0')

    def run_fixture(self,overwrite=False,fail_game=False,rollback_busy=False,reap_denied=False,sync_mode=None):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory).resolve();run=root/'run';run.mkdir();prefix=run/'prefix';prefix.mkdir();(run/'home').mkdir()
            game_dir=root/'game';game_dir.mkdir();game=game_dir/'Spider-Man2.exe';game.write_bytes(b'MZ')
            h=Harness(root,overwrite,fail_game)
            with contextlib.ExitStack() as stack:
                for obj,name,value in [(m.reuse,'RUN',run),(m.reuse,'PREFIX',prefix),(m.base,'GAME_DIR',game_dir),(m.base,'GAME',game),
                    (m.tx,'load_plan',h.plan),(m.tx,'prefix_identity',h.ident),(m.reuse,'require_idle_prefix',None),(m,'probe',h.probe),
                    (m.tx,'invoke',h.invoke),(m.base,'bounded_shutdown',h.shutdown),(m.base,'run_command',h.game),(m.base,'reap_child',None)]:
                    if callable(value): stack.enter_context(mock.patch.object(obj,name,side_effect=value))
                    elif name in ('load_plan','prefix_identity'): stack.enter_context(mock.patch.object(obj,name,return_value=value))
                    elif name in ('require_idle_prefix','reap_child'): stack.enter_context(mock.patch.object(obj,name,return_value=None))
                    else: stack.enter_context(mock.patch.object(obj,name,value))
                stack.enter_context(mock.patch.object(m.base,'Inspector',return_value=object()))
                if rollback_busy:
                    m.reuse.require_idle_prefix.side_effect=[None,RuntimeError('prefix became busy')]
                if reap_denied:m.base.reap_child.side_effect=PermissionError('denied')
                stack.enter_context(mock.patch.object(sys,'argv',['test','--run']))
                stack.enter_context(mock.patch('sys.stdout',new=io.StringIO()))
                rc=m.main(sync_mode=sync_mode)
            folder=next(run.glob('gpu-hardwareid-*'));receipt=json.loads((folder/'receipt.json').read_text());journal=json.loads((folder/'journal.json').read_text())
            return rc,h,receipt,journal
    def test_sync_overlay_is_pure_and_validated(self):
        original={'environment':{'WINEMSYNC':'0','WINEESYNC':'0','nested':{'v':[1]}},'other':{'x':1}}
        selected=m.with_sync_mode(original,'msync');self.assertEqual((selected['environment']['WINEMSYNC'],selected['environment']['WINEESYNC']),('1','0'))
        selected['environment']['nested']['v'].append(2);self.assertEqual(original['environment']['nested']['v'],[1]);self.assertEqual(original['environment']['WINEMSYNC'],'0')
        self.assertEqual(m.with_sync_mode(selected,'server')['environment']['WINEMSYNC'],'0')
        with self.assertRaises(ValueError):m.with_sync_mode(original,'invalid')
    def test_changed_identity_rejected_before_prefix_activity(self):
        plan={'engineFingerprint':'changed','rendererHash':'renderer','environment':{}}
        with mock.patch.object(sys,'argv',['test','--run']),mock.patch.object(sys,'platform','darwin'),mock.patch.object(m.tx,'load_plan',return_value=plan),mock.patch.object(m.tx,'prefix_identity') as identify:
            with self.assertRaisesRegex(RuntimeError,'changed'):m.main(sync_mode='msync',expected_identity=('original','renderer'))
            identify.assert_not_called()
    def test_msync_same_environment_for_helpers_game_and_cleanup(self):
        rc,h,receipt,journal=self.run_fixture(sync_mode='msync')
        self.assertEqual(rc,0);self.assertEqual({name for name,_ in h.environments},{'probe','helper','game','shutdown'})
        for _,env in h.environments:self.assertEqual((env.get('WINEMSYNC'),env.get('WINEESYNC')),('1','0'))
        self.assertEqual(h.plan['environment'],{});self.assertEqual(receipt['synchronization']['requested'],'msync');self.assertEqual(receipt['synchronization']['activation'],'unverified')
    def test_complete_transaction_restores_original(self):
        rc,h,receipt,journal=self.run_fixture()
        self.assertEqual(rc,0);self.assertIn('game',h.called);self.assertEqual(h.value,m.tx.ORIGINAL)
        self.assertEqual(receipt['rollback'],'verified_readback_and_shutdown');self.assertEqual(journal['state'],'rolled_back')
        self.assertLess(h.called.index('probe-after'),h.called.index('game'))
    def test_reap_permission_error_does_not_skip_rollback(self):
        rc,h,receipt,journal=self.run_fixture(reap_denied=True)
        self.assertEqual(rc,1)
        self.assertEqual(journal['state'],'rolled_back');self.assertEqual(h.value,m.tx.ORIGINAL)
        self.assertEqual(receipt['status'],'finished');self.assertEqual(receipt['rollback'],'verified_readback_and_shutdown')
        self.assertIn('PermissionError',receipt['reap_error'])
    def test_refresh_overwrite_stops_before_game_and_restores(self):
        rc,h,receipt,journal=self.run_fixture(overwrite=True)
        self.assertEqual(rc,1);self.assertNotIn('game',h.called);self.assertEqual(h.value,m.tx.ORIGINAL)
        self.assertEqual(receipt['rollback'],'verified_readback_and_shutdown');self.assertEqual(journal['state'],'rolled_back')
    def test_game_exception_triggers_undo(self):
        rc,h,receipt,journal=self.run_fixture(fail_game=True)
        self.assertEqual(rc,1);self.assertEqual(h.value,m.tx.ORIGINAL);self.assertIn('--undo',h.called)
        self.assertEqual(journal['state'],'rolled_back')
    def test_busy_prefix_blocks_undo_and_keeps_durable_journal(self):
        rc,h,receipt,journal=self.run_fixture(rollback_busy=True)
        self.assertEqual(rc,1);self.assertEqual(h.value,m.tx.REPLACEMENT)
        self.assertEqual(receipt['rollback'],'unknown_or_deferred');self.assertEqual(journal['state'],'applied')
        self.assertNotIn('--undo',h.called)
    def test_uncertain_process_does_not_authorize_rollback(self):
        old={'pid':100,'uid':1,'start_sec':2,'start_usec':3,'path':'/x'}
        class Inspector:
            def identity(self,pid):return old
        with self.assertRaises(RuntimeError):m.verify_stopped({(100,):old},Inspector())
    def test_reused_pid_is_not_mistaken_for_owned_process(self):
        old={'pid':100,'uid':1,'start_sec':2,'start_usec':3,'path':'/x'}
        class Inspector:
            def identity(self,pid):return dict(old,start_sec=4)
        self.assertEqual(m.verify_stopped({(100,):old},Inspector())[0]['status'],'reused')
    def test_probe_requires_exact_nonce_and_value(self):
        good={'schema':1,'kind':'playmelt-setupapi-display-probe','nonce':'n','setupComplete':True,'interfacesComplete':True,'setupDevices':[{'instanceId':m.INSTANCE,'hardwareId':m.tx.APPLE}]}
        m.require_observed(good,m.tx.APPLE,'n')
        with self.assertRaises(RuntimeError):m.require_observed(good,m.tx.AMD,'n')
        with self.assertRaises(RuntimeError):m.require_observed(good,m.tx.APPLE,'wrong')

    def test_fallback_undo_uses_durable_journal(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory).resolve();run=root/'run';run.mkdir();prefix=run/'prefix';prefix.mkdir()
            txn='a34d744b-4640-4c66-9aca-2d1796888371';folder=run/('gpu-hardwareid-'+txn);folder.mkdir()
            h=Harness(root);h.value=m.tx.REPLACEMENT
            with contextlib.ExitStack() as stack:
                stack.enter_context(mock.patch.object(m.reuse,'RUN',run));stack.enter_context(mock.patch.object(m.reuse,'PREFIX',prefix))
                stack.enter_context(mock.patch.object(m.tx,'load_plan',return_value=h.plan));stack.enter_context(mock.patch.object(m.tx,'prefix_identity',return_value=h.ident))
                stack.enter_context(mock.patch.object(m.reuse,'require_idle_prefix',return_value=None));stack.enter_context(mock.patch.object(m.tx,'invoke',side_effect=h.invoke))
                stack.enter_context(mock.patch.object(m.base,'bounded_shutdown',side_effect=h.shutdown));stack.enter_context(mock.patch.object(sys,'argv',['test','--undo',txn]))
                stack.enter_context(mock.patch('sys.stdout',new=io.StringIO()))
                record=m.record_for(h.plan,h.ident,txn);record['state']='applied';m.tx.durable_write(folder,record)
                self.assertEqual(m.tx.main(),0)
            self.assertEqual(h.value,m.tx.ORIGINAL)
            self.assertEqual(json.loads((folder/'journal.json').read_text())['state'],'rolled_back')

if __name__=='__main__': unittest.main()
