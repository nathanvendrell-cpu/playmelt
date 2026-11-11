import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('metal_analysis', ROOT/'scripts/analyze_metal_performance.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def sample(start=1, end=2, frames=30, gpu_count=10, gpu_total=200, config=True):
    layer = {'Performance Stats': {
        'Start MCT Seconds': start, 'End MCT Seconds': end, 'Duration MCT Seconds': end-start,
        'Presented Frame Stats': {'Frame Count': frames, 'FPS': frames/(end-start),
                                  'On-GPU Walltime Stats': {'Count': gpu_count,
                                     'Average (ms)': gpu_total/gpu_count if gpu_count else 0,
                                     'Total (ms)': gpu_total}}
    }}
    if config: layer['Configuration'] = {'Name':'WineMetalView', 'Width (pixels)':2560,
                                          'Height (pixels)':1600, 'MTL Pixel Format Name':'BGRA8Unorm'}
    return {'PID':123, 'Process':'wine', 'Layers':[layer]}


def stream(*objects):
    return '\n'.join(json.dumps(x, indent=2) for x in objects).encode()


class Tests(unittest.TestCase):
    def test_weighted_fps_and_gpu_separate_and_zero_reported(self):
        result = m.analyze(stream(sample(), sample(2,4,frames=60,gpu_count=30,gpu_total=300),
                                  sample(4,5,frames=0,gpu_count=0,gpu_total=0,config=False)), 123)
        group = result['groups'][0]
        self.assertEqual(group['presentedFrames'], 90)
        self.assertEqual(group['presentedFPS'], 30)
        self.assertEqual(group['gpuWalltimeMeanMs'], 12.5)
        self.assertEqual(result['skippedZeroFramesUnknownConfig'], 1)

    def test_wrong_pid_bool_negative_nan_and_overlap_fail(self):
        bad_pid = sample(); bad_pid['PID'] = 124
        bad_bool = sample(); bad_bool['Layers'][0]['Performance Stats']['Presented Frame Stats']['Frame Count'] = True
        negative = sample(); negative['Layers'][0]['Performance Stats']['Presented Frame Stats']['Frame Count'] = -1
        for obj in (bad_pid, bad_bool, negative):
            with self.assertRaises(ValueError): m.analyze(stream(obj), 123)
        with self.assertRaises(ValueError): m.analyze(stream(sample(), sample(1.5,2.5)), 123)
        with self.assertRaises(ValueError): m.analyze(b'{"PID":123,"Process":"wine","Layers":[],"x":1e999}', 123)
        with self.assertRaises(ValueError): m.analyze(b'{"PID":123,"PID":123}', 123)

    def test_active_missing_config_and_partial_rejected(self):
        with self.assertRaises(ValueError): m.analyze(stream(sample(config=False)), 123)
        with self.assertRaises(ValueError): m.analyze(b'{"PID":123', 123)

    def test_weighted_values_reject_inconsistent_total(self):
        obj = sample()
        obj['Layers'][0]['Performance Stats']['Presented Frame Stats']['On-GPU Walltime Stats']['Total (ms)'] = 1
        with self.assertRaises(ValueError): m.analyze(stream(obj),123)


if __name__ == '__main__': unittest.main()
