#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Preparatory private worker; no Galaxy import, login UI or download activation.

Native OAuth/Keychain contract (not implemented in the frozen app):
  acquireLease(owner,generation) -> {owner,generation,accountID,credentials}
  commitRefreshedLease(payload) -> CAS acknowledgement {owner,generation,accepted}
The native caller owns one lease/refresh at a time per account and cancels the
worker on account selection changes. Credentials use separate pipe descriptors.

Supported CLI operations: inspect-plan, verify, resume, refresh-auth. Production
download/repair fail explicitly until CDN/publication/native validation integrate.
"""
from __future__ import annotations

import argparse
import importlib
import logging
import os
import sys

from gog_worker_protocol import (Cancellation,Context,Events,Issue,OwnedRoot,Plan,
                                 private_pipe,read_pipe,verify,write_pipe)
from gog_worker_adapter import PinnedSource,bound_auth_manager,production_download


def main(argv=None):
    logging.disable(logging.CRITICAL)
    # Suppress argparse/upstream errors before parsing any command line.
    with open(os.devnull,'wb',buffering=0) as null:
        os.dup2(null.fileno(),1);os.dup2(null.fileno(),2)
    parser=argparse.ArgumentParser(description='Private preparatory GOG worker',add_help=False)
    parser.add_argument('--request-fd',type=int,required=True)
    parser.add_argument('--event-fd',type=int,required=True)
    parser.add_argument('--cancel-fd',type=int,required=True)
    parser.add_argument('--secret-fd',type=int)
    parser.add_argument('--secret-result-fd',type=int)
    parser.add_argument('--secret-ack-fd',type=int)
    parser.add_argument('--dependency-root')
    args=parser.parse_args(argv)
    context=events=None
    descriptors=[]
    try:
        pairs=[(args.request_fd,False),(args.event_fd,True),(args.cancel_fd,False)]
        auth_fds=[args.secret_fd,args.secret_result_fd,args.secret_ack_fd]
        if any(x is not None for x in auth_fds):
            if any(x is None for x in auth_fds):raise Issue('invalid_fd')
            pairs += [(args.secret_fd,False),(args.secret_result_fd,True),(args.secret_ack_fd,False)]
        identities=[private_pipe(fd,writing) for fd,writing in pairs]
        if len(set(identities))!=len(identities):raise Issue('aliased_fd')
        descriptors=[fd for fd,_ in pairs]
        request=read_pipe(args.request_fd,8*1024*1024)
        if type(request.get('schema')) is not int or request.get('schema')!=1:raise Issue('invalid_request')
        context=Context.parse(request)
        events=Events(context,lambda row:write_pipe(args.event_fd,row,65536))
        cancel=Cancellation(args.cancel_fd);cancel.check()
        operation=request.get('operation')
        if operation in ('download','repair'):
            production_download()
        elif operation=='refresh-auth':
            if request.get('networkAllowed') is not True:raise Issue('network_not_authorized',False,'session')
            if any(x is None for x in auth_fds) or not args.dependency_root:raise Issue('auth_channel_required')
            pinned=PinnedSource(args.dependency_root);pinned.install()
            module=importlib.import_module('gogdl.auth')
            lease=read_pipe(args.secret_fd,65536)
            def secret_sink(payload):
                cancel.check();write_pipe(args.secret_result_fd,payload,65536)
                ack=read_pipe(args.secret_ack_fd,4096)
                if set(ack)!={'owner','generation','accepted'} or ack.get('owner')!=context.owner or type(ack.get('generation')) is not int or ack.get('generation')!=payload['generation'] or ack.get('accepted') is not True:
                    raise Issue('auth_commit_rejected',False,'session')
            manager=bound_auth_manager(module,context,lease,secret_sink)
            try:
                credentials=manager.get_credentials()
                if not credentials:raise Issue('auth_required',False,'session')
                cancel.check()
                events.send('waiting','client','completed','session_available',terminal=True,resumePoint='plan')
            finally:manager.close()
        elif operation in ('inspect-plan','verify','resume'):
            plan=Plan.parse(context,request.get('plan'))
            if operation=='inspect-plan':
                events.send('waiting','engine','completed','plan_accepted',terminal=True,
                            requiresNativeValidation=True,planDigest=plan.digest,resumePoint='verify')
            else:
                # Resume is intentionally the same real-byte verification path.
                with OwnedRoot(request.get('root'),context) as root:verify(root,plan,events,cancel)
        else:raise Issue('operation_unsupported')
        return 0
    except Issue as error:
        if events:
            try:events.send('cancelled' if error.code=='cancelled' else 'failed','verify',
                            'cancelled' if error.code=='cancelled' else 'failed',error.code,
                            terminal=True,retryable=error.retryable,resumePoint=error.resume_point)
            except Issue:pass
        return 2 if error.code!='cancelled' else 130
    except BaseException:
        if events:
            try:events.send('failed','verify','failed','worker_failed',terminal=True,retryable=False,resumePoint='plan')
            except BaseException:pass
        return 2
    finally:
        for fd in descriptors:
            try:os.close(fd)
            except OSError:pass


if __name__=='__main__':sys.exit(main())
