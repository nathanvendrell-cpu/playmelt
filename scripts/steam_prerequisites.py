"""Inspect Valve install scripts as data only. Never execute their commands.

The Steam Windows client remains responsible for validating signatures and
running first-start scripts. A signature field alone is not authentication.
"""
import re
from pathlib import Path


def vdf(text):
    text=re.sub(r'(?m)^\s*//[^\n]*','',text)
    tokens=re.findall(r'"(?:\\.|[^"\\])*"|[{}]|[^\s{}"]+',text)
    if len(tokens)>20000:raise ValueError("InstallScript trop grand")
    def decoded(t):
        return re.sub(r'\\([\\"])',r'\1',t[1:-1]) if t.startswith('"') else t
    def obj(i,depth):
        if depth>32:raise ValueError("InstallScript trop imbriqué")
        result={}
        while i<len(tokens):
            if tokens[i]=='}':return result,i+1
            key=decoded(tokens[i]);i+=1
            if i>=len(tokens):raise ValueError("InstallScript incomplet")
            if tokens[i]=='{':value,i=obj(i+1,depth+1)
            else:value=decoded(tokens[i]);i+=1
            result[key.lower()]=value
        if depth:raise ValueError("InstallScript incomplet")
        return result,i
    return obj(0,0)[0]


def inspect_scripts(folder,depot_id=""):
    checks,issues=[],[]
    for path in Path(folder).rglob('*.vdf'):
        if path.is_symlink() or path.stat().st_size>65536:continue
        try:data=vdf(path.read_text(encoding='utf-8-sig'))
        except (OSError,ValueError,UnicodeError):continue
        script=data.get('installscript',{})
        if not isinstance(script,dict):continue
        processes=script.get('run process',{})
        if not isinstance(processes,dict):continue
        for description,entry in processes.items():
            if not isinstance(entry,dict):continue
            key=entry.get('hasrunkey','')
            allowed=re.fullmatch(r'HKEY_LOCAL_MACHINE\\SOFTWARE\\(?:Wow6432Node\\)?Valve\\Steam\\Apps\\CommonRedist(?:\\[^\r\n]+)?',key,re.I)
            minimum=str(entry.get('minimumhasrunvalue','1'))
            if not allowed or not minimum.isdigit() or not description or len(description)>200:
                issues.append({'kind':'official-installscript','depotID':depot_id,'message':'Un composant éditeur doit être finalisé par le client Steam Windows.'})
                continue
            checks.append({'depotID':depot_id,'key':key,'name':description,'minimum':max(1,int(minimum)),
                           'source':'Valve-installscript-data-only','signatureValidation':'Steam-client-required'})
    if depot_id and not checks:
        issues.append({'kind':'official-installscript','depotID':depot_id,'message':'Les composants Windows requis par Steam doivent être finalisés dans son client Windows.'})
    return checks,issues


def detect_renderer(files,arguments,app_id):
    flags={a.lower() for a in arguments}
    if str(app_id) in {'1783560','2584270','4711740','2651280','1903340'} or flags & {'-dx12','-d3d12','-force-d3d12'}:
        return 'd3dmetal','publisher-or-qualified-profile'
    if str(app_id)=='526870' or flags & {'-dx11','-d3d11','-force-d3d11'}:
        return 'dxmt','publisher-or-qualified-profile'
    # Bundled DLLs/plugins can support several APIs. Their presence alone does
    # not establish the API selected by this publisher's build.
    return 'auto','unknown'
