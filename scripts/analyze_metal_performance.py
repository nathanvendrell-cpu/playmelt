#!/usr/bin/env python3
"""Analyze reviewed metalperftrace aggregate windows, never infer per-frame percentiles."""
import argparse
import hashlib
import json
import math
from pathlib import Path

MAX_BYTES = 4 * 1024 * 1024


def pairs(items):
    result = {}
    for key, value in items:
        if key in result:
            raise ValueError('duplicate JSON key')
        result[key] = value
    return result


def nonfinite(_):
    raise ValueError('non-finite JSON number')


def finite_float(value):
    parsed = float(value)
    if not math.isfinite(parsed): raise ValueError('non-finite JSON number')
    return parsed


def number(value, name, *, integer=False):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or value < 0:
        raise ValueError('invalid ' + name)
    try:
        if not math.isfinite(value): raise ValueError('invalid ' + name)
    except OverflowError:
        raise ValueError('invalid ' + name) from None
    if integer and (not isinstance(value, int)):
        raise ValueError('non-integer ' + name)
    return value


def analyze(data, pid):
    if len(data) > MAX_BYTES: raise ValueError('capture exceeds size limit')
    text = data.decode('utf-8')
    decoder = json.JSONDecoder(object_pairs_hook=pairs, parse_constant=nonfinite, parse_float=finite_float)
    offset = 0
    groups = {}
    skipped_empty_unknown = 0
    skipped_empty_known = 0
    objects = 0
    process_name = None
    while True:
        while offset < len(text) and text[offset].isspace(): offset += 1
        if offset == len(text): break
        try: obj, offset = decoder.raw_decode(text, offset)
        except json.JSONDecodeError: raise ValueError('incomplete or invalid JSON') from None
        if type(obj) is not dict or type(obj.get('PID')) is not int or obj['PID'] != pid:
            raise ValueError('invalid or mismatched PID')
        if not isinstance(obj.get('Process'), str) or not obj['Process']:
            raise ValueError('missing process name')
        if process_name is not None and process_name != obj['Process']:
            raise ValueError('process name changed')
        process_name = obj['Process']
        if not isinstance(obj.get('Layers'), list): raise ValueError('missing Layers')
        objects += 1
        for layer in obj['Layers']:
            if type(layer) is not dict or type(layer.get('Performance Stats')) is not dict:
                raise ValueError('unknown layer schema')
            stats = layer['Performance Stats']
            start = number(stats.get('Start MCT Seconds'), 'start')
            end = number(stats.get('End MCT Seconds'), 'end')
            duration = number(stats.get('Duration MCT Seconds'), 'duration')
            if end <= start or duration <= 0 or abs((end-start)-duration) > 0.00001:
                raise ValueError('invalid measurement interval')
            presented = stats.get('Presented Frame Stats')
            if type(presented) is not dict: raise ValueError('missing presented-frame stats')
            count = number(presented.get('Frame Count'), 'frame count', integer=True)
            number(presented.get('FPS'), 'reported FPS')
            gpu = presented.get('On-GPU Walltime Stats')
            if type(gpu) is not dict: raise ValueError('missing GPU walltime stats')
            gpu_count = number(gpu.get('Count'), 'GPU count', integer=True)
            gpu_average = number(gpu.get('Average (ms)'), 'GPU average')
            gpu_total = number(gpu.get('Total (ms)'), 'GPU total')
            if abs(gpu_average * gpu_count - gpu_total) > max(0.01, gpu_total * 0.00001):
                raise ValueError('inconsistent GPU walltime')
            config = layer.get('Configuration')
            if not count:
                if config is None: skipped_empty_unknown += 1
                else: skipped_empty_known += 1
                continue
            if type(config) is not dict or not isinstance(config.get('Name'), str) or not config['Name']:
                raise ValueError('active interval has unknown configuration')
            width = number(config.get('Width (pixels)'), 'width', integer=True)
            height = number(config.get('Height (pixels)'), 'height', integer=True)
            if not width or not height: raise ValueError('invalid display size')
            pixel_format = config.get('MTL Pixel Format Name')
            if not isinstance(pixel_format, str) or not pixel_format: raise ValueError('missing pixel format')
            key = (config['Name'], width, height, pixel_format)
            group = groups.setdefault(key, {'intervals': [], 'frames': 0, 'duration': 0.0,
                                             'gpuCount': 0, 'gpuTotalMs': 0.0})
            group['intervals'].append((start, end))
            group['frames'] += count; group['duration'] += duration
            group['gpuCount'] += gpu_count; group['gpuTotalMs'] += gpu_total
    if not objects: raise ValueError('empty capture')
    output = []
    for (name, width, height, pixel_format), group in sorted(groups.items()):
        intervals = sorted(group['intervals'])
        if any(b[0] < a[1] - 0.0000001 for a, b in zip(intervals, intervals[1:])):
            raise ValueError('overlapping measurement windows')
        output.append({'layer': name, 'width': width, 'height': height, 'pixelFormat': pixel_format,
                       'windows': len(intervals), 'durationSeconds': group['duration'],
                       'presentedFrames': group['frames'], 'presentedFPS': group['frames']/group['duration'],
                       'gpuWalltimeSamples': group['gpuCount'],
                       'gpuWalltimeMeanMs': group['gpuTotalMs']/group['gpuCount'] if group['gpuCount'] else None})
    if not output: raise ValueError('no active windows with known configuration')
    return {'status': 'analyzed', 'sourceSHA256': hashlib.sha256(data).hexdigest(),
            'pid': pid, 'objects': objects, 'skippedZeroFramesUnknownConfig': skipped_empty_unknown,
            'skippedZeroFramesKnownConfig': skipped_empty_known, 'groups': output,
            'limitations': ['Per-window aggregate, not per-frame P95.',
                            'GPU walltime is command-buffer timing, not GPU utilization.',
                            'Presented frame count does not establish generated-frame count.',
                            'Game settings can change within a capture; compare only controlled sessions.']}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('capture', type=Path)
    parser.add_argument('--pid', type=int, required=True)
    args = parser.parse_args()
    if args.pid <= 0: parser.error('pid must be positive')
    try:
        with args.capture.open('rb') as capture:
            result = analyze(capture.read(MAX_BYTES + 1), args.pid)
    except (ValueError, OSError, UnicodeDecodeError) as exc:
        print(json.dumps({'status': 'inconclusive', 'reason': str(exc)}))
        return 1
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
