#!/usr/bin/env python3
"""Review required: --run launches the real game in the isolated experiment.

Runs the existing HardwareID CAS/probe/undo workflow unchanged. Adds only the
explicitly selected game flag; a 300-second diagnostic is opt-in, never a
product timeout. No UI inspection or input is performed by this wrapper.
"""
import json
from pathlib import Path
import sys
import m3_hardwareid_experiment as experiment
import m3_private_supervisor as supervisor
import m3_reuse_diagnostic as reuse


def game_run(original,argv,env,directory,log,timeout,inspector,marker,seen,*,seconds):
    expected_game=len(argv)==2 and argv[1]==str(supervisor.GAME)
    if expected_game:
        if (env.get('WINEPREFIX')!=str(reuse.PREFIX) or timeout!=120 or
            directory!=str(supervisor.GAME_DIR) or not marker):
            raise RuntimeError('unexpected prefix, game directory, marker or timeout')
        profile={'game_arguments':['-nolauncher'],'game_timeout_seconds':seconds,
                 'launch_mode':'direct','diagnostic_only':True,
                 'limitations':['Game argument behavior requires real validation.',
                                'This timeout is not a product play-session limit.']}
        with (Path(log.name).parent/'nolauncher-profile.json').open('x',encoding='utf-8') as f:
            json.dump(profile,f,indent=2,sort_keys=True);f.write('\n')
        return original(argv+['-nolauncher'],env,directory,log,seconds,inspector,marker,seen)
    return original(argv,env,directory,log,timeout,inspector,marker,seen)


def main():
    valid=([sys.argv[0],'--run','--nolauncher'],[sys.argv[0],'--run','--nolauncher','--timeout','300'])
    if sys.argv not in valid:
        print('Review required. Use --run --nolauncher [--timeout 300].',file=sys.stderr);return 64
    seconds=300 if len(sys.argv)==5 else 120
    original_run=supervisor.run_command; original_argv=sys.argv
    try:
        supervisor.run_command=lambda *args: game_run(original_run,*args,seconds=seconds)
        sys.argv=[original_argv[0],'--run']
        return experiment.main()
    finally:
        sys.argv=original_argv;supervisor.run_command=original_run

if __name__=='__main__':sys.exit(main())
