import json, os, pathlib, subprocess, tempfile, unittest, shutil

REPO = pathlib.Path(__file__).resolve().parents[1]
class Contract(unittest.TestCase):
    def run_phase(self, phase, known='host key', state_inside=False):
        with tempfile.TemporaryDirectory() as work, tempfile.TemporaryDirectory(dir=pathlib.Path.home()) as permanent:
            checkout=pathlib.Path(work)/'checkout';checkout.mkdir();(checkout/'scripts').mkdir()
            shutil.copy(REPO/'ci/deploy.sh',checkout/'deploy.sh')
            shutil.copy(REPO/'variables.tf',checkout/'variables.tf')
            (checkout/'scripts/deploy.sh').write_text('#!/bin/bash\necho bootstrap >> "$MOCK_LOG"\n');(checkout/'scripts/deploy.sh').chmod(0o755)
            bins=pathlib.Path(work)/'bin';bins.mkdir();log=pathlib.Path(work)/'log'
            mock='''#!/usr/bin/env python3
import os,sys,json
from pathlib import Path
name=Path(sys.argv[0]).name
with open(os.environ['MOCK_LOG'],'a') as f:f.write(json.dumps([name,*sys.argv[1:]])+'\\n')
if name=='ssh-agent' and '-s' in sys.argv: print('export SSH_AGENT_PID=99999;')
if name=='ssh-keygen': print('ssh-ed25519 MOCK_PUBLIC_KEY')
if name=='terraform' and 'output' in sys.argv: print('192.0.2.50')
'''
            for name in ['terraform','ssh-agent','ssh-add','ssh-keygen','ssh','flock']:
                f=bins/name;f.write_text(mock);f.chmod(0o755)
            env=os.environ.copy();env.update(PATH=str(bins)+':'+env['PATH'],MOCK_LOG=str(log),TF_STATE_ROOT=str(checkout if state_inside else permanent),HOMELAB_STATE_ID='github-123',HOMELAB_TFVARS_JSON='{"vm_name":"demo"}',PROXMOX_VE_ENDPOINT='https://example.test:8006/',PROXMOX_VE_API_TOKEN='MOCK_NOT_A_CREDENTIAL',SSH_PRIVATE_KEY='MOCK_NOT_A_KEY',SSH_KNOWN_HOSTS=known,LAB_HOSTNAME='demo.example.test',IMAGE='example/service:1.0.0',HOMELAB_ACTION=phase)
            result=subprocess.run(['bash','deploy.sh'],cwd=checkout,env=env,capture_output=True,text=True)
            events=log.read_text().splitlines() if log.exists() else []
            self.assertFalse((checkout/'terraform.tfvars.json').exists())
            return result,events
    def test_plan_never_applies_or_bootstraps(self):
        r,events=self.run_phase('plan',known='');self.assertEqual(r.returncode,0,r.stderr)
        self.assertTrue(any('"plan"' in e for e in events));self.assertFalse(any('"apply"' in e or e=='bootstrap' for e in events))
    def test_provision_applies_without_ssh_known_hosts(self):
        r,events=self.run_phase('provision',known='');self.assertEqual(r.returncode,0,r.stderr)
        self.assertTrue(any('"apply"' in e for e in events));self.assertFalse(any(e.startswith('["ssh",') or e=='bootstrap' for e in events))
    def test_deploy_applies_then_bootstraps(self):
        r,events=self.run_phase('deploy');self.assertEqual(r.returncode,0,r.stderr)
        self.assertLess(next(i for i,e in enumerate(events) if '"apply"' in e),events.index('bootstrap'))
    def test_deploy_without_trust_fails_before_apply(self):
        r,events=self.run_phase('deploy',known='');self.assertNotEqual(r.returncode,0);self.assertFalse(events)
    def test_checkout_state_rejected(self):
        r,events=self.run_phase('plan',state_inside=True);self.assertNotEqual(r.returncode,0);self.assertFalse(events)
if __name__=='__main__':unittest.main()
