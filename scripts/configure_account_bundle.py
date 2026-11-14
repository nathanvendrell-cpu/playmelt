#!/usr/bin/env python3
"""Public native account configuration; no payment or signing secrets."""
import base64
import json
import os
from pathlib import Path
import plistlib
import sys
from urllib.parse import urlsplit

def update_configuration(public, account_url, ready, enforced, env):
    qualified=env.get('PLAYMELT_UPDATES_READY','1' if public.get('updatesReady') is True else '0')
    if qualified not in ('0','1'):raise ValueError('Update readiness must be 0 or 1')
    enabled=qualified=='1'
    values={'PlaymeltAutomaticUpdatesAvailable':enabled,'PlaymeltUpdatesRequireAuthentication':enabled,
            'SUEnableAutomaticChecks':enabled,'SUAllowsAutomaticUpdates':enabled,'SUAutomaticallyUpdate':enabled}
    if not enabled:return values
    if ready!='1' or not enforced:raise ValueError('Authenticated updates require an enforced configured account service')
    feed=env.get('PLAYMELT_UPDATE_FEED_URL',public.get('updateFeedURL',''))
    key=env.get('PLAYMELT_UPDATE_PUBLIC_KEY',public.get('updatePublicKey',''))
    expected=account_url.rstrip('/')+'/v1/updates/appcast.xml'
    url=urlsplit(feed)
    if feed!=expected or any(ord(char)<33 for char in feed) or url.scheme!='https' or url.username or url.password or url.query or url.fragment:
        raise ValueError('Updates require the fixed same-origin authenticated feed; no public fallback')
    try:decoded=base64.b64decode(key,validate=True)
    except (ValueError,TypeError):raise ValueError('Invalid update Ed25519 public key')
    if len(decoded)!=32 or decoded==bytes(32) or base64.b64encode(decoded).decode()!=key:
        raise ValueError('Invalid update Ed25519 public key')
    values.update({'SUFeedURL':feed,'SUPublicEDKey':key})
    return values

def configuration(path, release, env, owner=False):
    if release and owner:raise ValueError('Internal owner and commercial release modes are exclusive')
    channel=env.get('PLAYMELT_CLIENT_CREDENTIAL_CHANNEL')
    if 'PLAYMELT_CLIENT_CREDENTIAL_CHANNEL' in env:
        if channel!='adhoc-login-v1':raise ValueError('Unknown explicit client credential channel')
        if not release or owner:raise ValueError('The ad hoc client credential channel requires a qualified client release')
    public=json.loads(Path(path).read_text())
    url=env.get('PLAYMELT_ACCOUNT_URL',public.get('accountURL',''))
    key=env.get('PLAYMELT_LICENSE_PUBLIC_KEY',public.get('licensePublicKey',''))
    ready=env.get('PLAYMELT_ACCOUNT_SERVICE_READY','1' if public.get('serviceReady') is True else '0')
    password_ready=env.get('PLAYMELT_PASSWORD_LOGIN_READY','1' if public.get('passwordLoginReady') is True else '0')
    google_ready=env.get('PLAYMELT_GOOGLE_LOGIN_READY','1' if public.get('googleLoginReady') is True else '0')
    if ready not in ('0','1'):raise ValueError('Account service readiness must be 0 or 1')
    if password_ready not in ('0','1') or (password_ready=='1' and ready!='1'):raise ValueError('Password login readiness requires the hosted account service')
    if google_ready not in ('0','1') or (google_ready=='1' and ready!='1'):raise ValueError('Google login readiness requires the hosted account service')
    u=urlsplit(url)
    if u.scheme!='https' or not u.hostname or u.username or u.password or u.query or u.fragment or len(base64.b64decode(key,validate=True))!=32:raise ValueError('Invalid public account configuration')
    if release and (ready!='1' or env.get('PLAYMELT_ACCOUNT_VERIFIED')!='1'):raise ValueError('Hosted account/device verification is required before account enforcement')
    if release and password_ready!='1':raise ValueError('Hosted password login verification is required before commercial activation')
    if owner and ready!='1':raise ValueError('Internal owner builds require the hosted account service')
    enforced=release or owner
    values={'PlaymeltAccountURL':url,'PlaymeltLicensePublicKey':key,'PlaymeltAccountServiceAvailable':ready=='1','PlaymeltPasswordLoginAvailable':password_ready=='1','PlaymeltGoogleLoginAvailable':google_ready=='1','PlaymeltCommercialAccessEnabled':enforced,'PlaymeltDevelopmentBuild':not enforced,'PlaymeltInternalBuild':owner}
    if channel=='adhoc-login-v1':values['PlaymeltClientCredentialChannel']=channel
    values.update(update_configuration(public,url,ready,enforced,env))
    return values

def main(argv):
    if len(argv) not in (4,5) or argv[1] not in ('--check','--write') or argv[3] not in ('0','1','owner'):raise ValueError('Invalid bundle configuration command')
    values=configuration(argv[2],argv[3]=='1',os.environ,owner=argv[3]=='owner')
    if argv[1]=='--write':
        if len(argv)!=5:raise ValueError('Bundle plist path required')
        path=Path(argv[4]);data=plistlib.loads(path.read_bytes());data.update(values)
        if 'PlaymeltClientCredentialChannel' not in values:data.pop('PlaymeltClientCredentialChannel',None)
        if values['PlaymeltCommercialAccessEnabled']:data.pop('MetalMaxSourceDirectory',None)
        if not values['PlaymeltAutomaticUpdatesAvailable']:data.pop('SUFeedURL',None)
        path.write_bytes(plistlib.dumps(data))
    return 0

if __name__=='__main__':
    try:sys.exit(main(sys.argv))
    except (ValueError,KeyError) as error:sys.exit(str(error))
