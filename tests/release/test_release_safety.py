import datetime, hashlib, importlib.util, json, tempfile, unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
def module(name):
    spec=importlib.util.spec_from_file_location(name, ROOT/'scripts'/f'{name}.py')
    mod=importlib.util.module_from_spec(spec); spec.loader.exec_module(mod); return mod
exporter=module('export_public'); gate=module('release_preflight')
class ReleaseSafety(unittest.TestCase):
    def test_private_files_never_selected(self):
        for name in ['.git/config','qa/live-delivery/receipts.json','assets/approved/a.png',
                     'config/Signing.local.xcconfig','workers/lite/.dev.vars','workers/lite/wrangler.production.jsonc',
                     'packages/QuotaProviderReference/Tests/A.swift','native/Phone/key.p8',
                     'native/../.git/config','workers/lite/node_modules/pkg/a.js']:
            self.assertFalse(exporter.allowed(name), name)
        for name in ['apps/macos/MacModel.swift','workers/lite/src/worker.ts','Package.resolved','config/Signing.xcconfig']:
            self.assertTrue(exporter.allowed(name), name)
    def test_evidence_requires_hash_commit_and_gate_content(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); (root/'.release').mkdir(); gates=[]
            for name in gate.REQUIRED:
                data=(name+' physical evidence').encode(); (root/'.release'/name).write_bytes(data)
                gates.append(dict(id=name,verified=True,evidence='.release/'+name,sha256=hashlib.sha256(data).hexdigest(),
                                  commit='a'*40,verifier='maintainer',verifiedAt='2026-01-01T00:00:00Z'))
            self.assertEqual(gate.validate(root,{'gates':gates},'a'*40),[])
            self.assertTrue(gate.validate(root,{'gates':gates},'b'*40))
            (root/gates[0]['evidence']).write_text('changed')
            self.assertIn(gates[0]['id'],gate.validate(root,{'gates':gates},'a'*40))
            gates[0]['evidence']='../outside'
            self.assertIn(gates[0]['id'],gate.validate(root,{'gates':gates},'a'*40))
            self.assertTrue(gate.validate(root,{'gates':[]},'a'*40))
    def test_internal_testflight_has_separate_exact_artifact_and_gate_set(self):
        artifact = {'appID':'123', 'bundleID':'com.example.ammo', 'version':'0.1.4',
                    'buildNumber':'4', 'ipaSha256':'b'*64}
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); (root/'.release').mkdir(); gates=[]
            for name in gate.INTERNAL_TESTFLIGHT_REQUIRED:
                data=json.dumps({'gateID':name,'commit':'a'*40,'artifact':artifact,
                                 'statement':'Verified for internal testing'}).encode()
                (root/'.release'/name).write_bytes(data)
                gates.append(dict(id=name,verified=True,evidence='.release/'+name,sha256=hashlib.sha256(data).hexdigest(),
                                  commit='a'*40,verifier='release operator',verifiedAt='2026-01-01T00:00:00Z'))
            document={'profile':'internal-testflight','artifact':artifact,'gates':gates}
            self.assertEqual(gate.validate(root,document,'a'*40,'internal-testflight',artifact),[])
            self.assertTrue(gate.validate(root,document,'a'*40,'formal'))
            self.assertTrue(gate.validate(root,document,'b'*40,'internal-testflight',artifact))
            self.assertIn('internal TestFlight artifact or profile mismatch',
                          gate.validate(root,document,'a'*40,'internal-testflight',{**artifact,'buildNumber':'5'}))
            self.assertIn('internal TestFlight artifact or profile mismatch',
                          gate.validate(root,{**document,'profile':'formal'},'a'*40,'internal-testflight',artifact))
            self.assertIn('required gate set missing or duplicated',
                          gate.validate(root,{**document,'gates':gates[:-1]},'a'*40,'internal-testflight',artifact))
            self.assertIn('required gate set missing or duplicated',
                          gate.validate(root,{**document,'gates':gates+[gates[0]]},'a'*40,'internal-testflight',artifact))
            evidence=root/gates[0]['evidence']
            stale=json.loads(evidence.read_text()); stale['commit']='b'*40
            evidence.write_text(json.dumps(stale)); gates[0]['sha256']=hashlib.sha256(evidence.read_bytes()).hexdigest()
            self.assertIn(gates[0]['id'],gate.validate(root,document,'a'*40,'internal-testflight',artifact))
            stale['commit']='a'*40; stale['artifact']={**artifact,'buildNumber':'3'}
            evidence.write_text(json.dumps(stale)); gates[0]['sha256']=hashlib.sha256(evidence.read_bytes()).hexdigest()
            self.assertIn(gates[0]['id'],gate.validate(root,document,'a'*40,'internal-testflight',artifact))
            (root/'tracked-document.md').write_text(gates[0]['id'])
            gates[0]['evidence']='tracked-document.md'
            gates[0]['sha256']=hashlib.sha256((root/'tracked-document.md').read_bytes()).hexdigest()
            self.assertIn(gates[0]['id'],gate.validate(root,document,'a'*40,'internal-testflight',artifact))
            gates[0]['evidence']='.release/'+gates[1]['id']
            gates[0]['sha256']=gates[1]['sha256']
            self.assertIn(gates[0]['id'],gate.validate(root,document,'a'*40,'internal-testflight',artifact))
            gates[0]['evidence']='.release/'+gates[0]['id']
            (root/gates[0]['evidence']).write_text('tampered')
            self.assertIn(gates[0]['id'],gate.validate(root,document,'a'*40,'internal-testflight',artifact))
if __name__=='__main__':unittest.main()
