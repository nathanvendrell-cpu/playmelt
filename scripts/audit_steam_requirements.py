#!/usr/bin/env python3
"""One-shot read-only publisher requirements audit. No Steam credentials."""
import datetime
import hashlib
import html
import json
from pathlib import Path
import re
import sys
import time
import urllib.error
import urllib.request


def profile(data):
    requirements=data.get('pc_requirements',{})
    minimum=requirements.get('minimum','') if isinstance(requirements,dict) else ''
    text=html.unescape(re.sub('<[^>]+>',' ',minimum))
    text=re.sub(r'\s+',' ',text)
    match=re.search(r'DirectX\s*:?\s*(?:Version\s*)?(9(?:\.0c)?|10(?:\.1)?|11(?:\.\d+)?|12(?:\.\d+)?)\b',text,re.I)
    api=match[1] if match else None
    # API requirements are publisher declarations, never a game benchmark.
    # DXMT translates D3D10/11, not D3D9. A minimum is only a candidate:
    # a multi-API game can select a different default at launch.
    renderer='d3dmetal' if api and api.startswith('12') else 'dxmt' if api and api.startswith(('10','11')) else 'auto'
    return {'graphicsAPI':('DirectX '+api) if api else 'unknown','rendererCandidate':renderer,
            'evidence':'publisher-minimum-requirements' if api else 'no-explicit-api',
            'minimumSHA256':hashlib.sha256(minimum.encode()).hexdigest()}


def main():
    if len(sys.argv)!=4:raise SystemExit('Usage: audit_steam_requirements.py catalog.json receipt.json profiles.json')
    catalog=json.loads(Path(sys.argv[1]).read_text())
    ids=sorted({g['appId'] for g in catalog['games'] if re.fullmatch(r'[1-9][0-9]{0,9}',g['appId'])},key=int)
    now=datetime.datetime.now(datetime.timezone.utc).isoformat()
    result={'schemaVersion':1,'retrievedAt':now,'scope':'Publisher requirements; no ownership or runtime validation','apps':{}}
    for appid in ids:
        url='https://store.steampowered.com/api/appdetails?appids='+appid+'&filters=basic,pc_requirements&l=english'
        entry={'source':url,'retrievedAt':datetime.datetime.now(datetime.timezone.utc).isoformat()}
        try:
            request=urllib.request.Request(url,headers={'User-Agent':'Playmelt-CompatibilityAudit/2.2'})
            with urllib.request.urlopen(request,timeout=20) as response:
                raw=response.read(1_000_001)
                if len(raw)>1_000_000:raise ValueError('Oversize public response')
                body=json.loads(raw)
            row=body.get(appid,{})
            if row.get('success') is True:
                data=row.get('data',{})
                entry.update(profile(data),success=True,name=data.get('name',''),minimum=data.get('pc_requirements',{}))
            else:entry.update(success=False,error='Store entry unavailable',renderer='auto',graphicsAPI='unknown')
        except (OSError,ValueError,TypeError) as error:
            entry.update(success=False,error=type(error).__name__,renderer='auto',graphicsAPI='unknown')
        result['apps'][appid]=entry
        # Periodic local checkpoint permits clean interruption and inspection.
        Path(sys.argv[2]).write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
        print(json.dumps({'appID':appid,'success':entry['success'],'api':entry['graphicsAPI']}),flush=True)
        time.sleep(3)  # courtesy to the public API; not a game resource policy
    profiles={'schemaVersion':1,'retrievedAt':now,'apps':{i:{k:v for k,v in r.items() if k in ['graphicsAPI','rendererCandidate','evidence','source','retrievedAt','minimumSHA256']} for i,r in result['apps'].items()}}
    Path(sys.argv[3]).write_text(json.dumps(profiles,ensure_ascii=False,indent=2)+'\n')


if __name__=='__main__':main()
