#!/usr/bin/env python3
"""Compile small GOG sources with CURRENT Core/main method bodies and inert dependencies."""
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import tempfile
import uuid

ROOT=Path(__file__).resolve().parents[1]


def block(source, marker):
    start=source.index(marker);opening=source.index('{',start)
    depth=0;quoted=False;escaped=False;line_comment=False
    for position in range(opening,len(source)):
        char=source[position]
        if line_comment:
            if char=='\n':line_comment=False
            continue
        if quoted:
            if escaped:escaped=False
            elif char=='\\':escaped=True
            elif char=='"':quoted=False
            continue
        if char=='"':quoted=True;continue
        if source[position:position+2]=='//':line_comment=True;continue
        if char=='{':depth+=1
        elif char=='}':
            depth-=1
            if depth==0:return source[start:position+1]
    raise RuntimeError('current source block is incomplete')


def main():
    sources=['OwnedProcess.swift','GOGConnector.swift','GOGInstallObserver.swift','Core.swift','main.swift',
             'tests/GOGInstallObserverTests.swift','tests/GOGCacheMergeFlowTests.swift',str(Path(__file__).relative_to(ROOT))]
    def hashes():return {name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in sources}
    before=hashes();core=(ROOT/'Core.swift').read_text();main_source=(ROOT/'main.swift').read_text()
    apply=block(core,'@discardableResult func applyScan(')
    refresh=block(main_source,'func refresh(completion:')
    callback=block(main_source,'model.gogConnector.onUpdate =')
    projection=re.search(r'#if GOG_CONNECTOR_ISOLATED_TESTS\n(.*?)\n#endif',(ROOT/'tests/GOGInstallObserverTests.swift').read_text(),re.S).group(1)
    glue='import Foundation\n'+projection+'\nextension FixtureModel {\n'+apply+'\n}\nextension FixtureHandler {\n'+refresh+'\nfunc attachCurrentGOGCallback(){\n'+callback+'\n}\n}\n'
    identity=uuid.uuid4().hex;products=ROOT/'Products.noindex'
    source=products/('gog-cache-merge-current-'+identity+'.swift');binary=source.with_suffix('');receipt=source.with_suffix('.json')
    source.write_text(glue)
    record={'startedAt':datetime.datetime.now(datetime.timezone.utc).isoformat(),'kind':'current extracted Core.applyScan/main.refresh/GOG callback; dependencies inert',
            'hashesBefore':before,'extractedBodySHA256':{name:hashlib.sha256(text.encode()).hexdigest() for name,text in [('Core.applyScan',apply),('main.refresh',refresh),('main.GOGCallback',callback)]},'processes':[],'valid':False}
    try:
        commands=[('compile',['swiftc','-j','1','-Onone','OwnedProcess.swift','GOGConnector.swift','GOGInstallObserver.swift',str(source),'tests/GOGCacheMergeFlowTests.swift','-o',str(binary),'-framework','AppKit'],90),('test',[str(binary)],30)]
        for role,command,timeout in commands:
            if hashes()!=before:raise RuntimeError('source changed before execution')
            process=subprocess.Popen(command,cwd=ROOT,start_new_session=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
            entry={'role':role,'pid':process.pid};record['processes'].append(entry)
            try:
                try:output=process.communicate(timeout=timeout)[0]
                except BaseException:
                    if process.poll() is None:os.killpg(process.pid,signal.SIGTERM)
                    try:process.communicate(timeout=3)
                    except subprocess.TimeoutExpired:os.killpg(process.pid,signal.SIGKILL);process.communicate()
                    raise
            finally:
                entry['exitCode']=process.returncode
                try:os.kill(process.pid,0);entry['reaped']=False
                except ProcessLookupError:entry['reaped']=True
            record[role+'Output']=output
            print(role+' PID '+str(process.pid)+' exit '+str(process.returncode),flush=True)
            if output:print(output,end='',flush=True)
            if process.returncode:raise RuntimeError(role+' failed')
        record['hashesAfter']=hashes();record['valid']=record['hashesAfter']==before and all(p['reaped'] for p in record['processes'])
    finally:
        source.unlink(missing_ok=True);binary.unlink(missing_ok=True)
        record['temporarySourceAndBinaryRemoved']=not source.exists() and not binary.exists()
        record['finishedAt']=datetime.datetime.now(datetime.timezone.utc).isoformat()
        receipt.write_text(json.dumps(record,indent=2)+'\n');print('receipt '+str(receipt),flush=True)
    return 0 if record['valid'] else 1


if __name__=='__main__':raise SystemExit(main())
