#!/usr/bin/env python3
"""Review required: --run launches the real game; software traces only.

Reuse the private-prefix admission, 120s timeout and scoped cleanup from
m3_reuse_diagnostic. No window enumeration, inspection, screenshots or input.
"""
import json
from pathlib import Path
import sys

import m3_private_supervisor as supervisor
import m3_reuse_diagnostic as reuse

# +msgbox is separate from +dialog in Wine 10 and may log message text.
# Logs can contain sensitive data; they remain local, capped by supervisor.
DEBUG_CHANNELS='fixme-all,+dialog,+msgbox,+seh'


def dialog_run(original, argv, env, directory, log, timeout, inspector, marker, seen, *, nolauncher=False, direct=False):
    if (env.get('WINEPREFIX')!=str(reuse.PREFIX) or timeout!=120 or
        argv!=supervisor.game_command(argv[0],supervisor.GAME)):
        raise RuntimeError('unexpected diagnostic command, prefix or timeout')
    run_env=dict(env)
    run_env['WINEDEBUG']=DEBUG_CHANNELS
    final_argv=([argv[0],str(supervisor.GAME)] if direct else argv)+(['-nolauncher'] if nolauncher else [])
    profile={'mode':'wine_software_traces','wine_debug':DEBUG_CHANNELS,'samples_enabled':False,'nolauncher_requested':nolauncher,
             'launch_mode':'direct' if direct else 'virtual_desktop',
             'timeout_seconds':120,'stream_cap_bytes':supervisor.MAX_LOG,
             'limitations':['Logging may truncate before relevant events.',
                            'Dialog traces do not prove a visible window or explain its state.',
                            'Wine debug traces may contain sensitive information.']}
    with (Path(log.name).parent/'diagnostic-profile.json').open('x',encoding='utf-8') as f:
        json.dump(profile,f,indent=2,sort_keys=True); f.write('\n')
    return original(final_argv,run_env,directory,log,timeout,inspector,marker,seen)


def no_samples(*args):
    """Do not invoke sample, vmmap, lsof on a process or any window API."""
    return None


def main():
    options=sys.argv[2:]
    if len(sys.argv)<2 or sys.argv[1]!='--run' or len(options)!=len(set(options)) or not set(options).issubset({'--nolauncher','--direct'}):
        print('Review required; accepted options: --run [--direct] [--nolauncher].',file=sys.stderr)
        return 64
    use_nolauncher='--nolauncher' in options
    use_direct='--direct' in options
    original_run=supervisor.run_command
    original_collect=reuse.collect
    original_argv=sys.argv
    try:
        supervisor.run_command=lambda *args: dialog_run(original_run,*args,nolauncher=use_nolauncher,direct=use_direct)
        reuse.collect=no_samples
        sys.argv=[original_argv[0],'--run']
        return reuse.main()
    finally:
        sys.argv=original_argv
        supervisor.run_command=original_run
        reuse.collect=original_collect

if __name__=='__main__': sys.exit(main())
