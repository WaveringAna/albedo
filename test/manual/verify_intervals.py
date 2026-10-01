import importlib.util
import random
import sys
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "candidate", Path(sys.argv.pop(1)) / "interval_set.py"
)
assert spec is not None and spec.loader is not None
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def points(intervals):
    return {x for a, b in intervals for x in range(a, b)}


def canonical(values):
    out = []
    for value in sorted(values):
        if out and out[-1][1] == value:
            out[-1] = (out[-1][0], value + 1)
        else:
            out.append((value, value + 1))
    return out


class IndependentTests(unittest.TestCase):
    def test_boundaries(self):
        self.assertEqual(
            m.normalize([(5, 5), (2, 4), (0, 2), (1, 3), (0, 2)]), [(0, 4)]
        )
        self.assertEqual(m.intersection([(0, 2)], [(2, 4)]), [])
        self.assertEqual(
            m.difference([(0, 10)], [(2, 4), (6, 8)]), [(0, 2), (4, 6), (8, 10)]
        )
        self.assertEqual(m.difference([(0, 10)], [(-1, 11)]), [])
        self.assertEqual(m.union([], []), [])

    def test_huge_endpoints(self):
        h = 10**100
        self.assertEqual(m.union([(-h, 0)], [(0, h)]), [(-h, h)])
        self.assertEqual(m.difference([(-h, h)], [(-1, 1)]), [(-h, -1), (1, h)])
        self.assertEqual(m.intersection([(-h, h)], [(h - 1, h + 1)]), [(h - 1, h)])

    def test_reversed_rejected(self):
        with self.assertRaises(ValueError):
            m.normalize([(2, 1)])
        for fn in (m.union, m.intersection, m.difference):
            with self.assertRaises(ValueError):
                fn([], [(2, 1)])
            with self.assertRaises(ValueError):
                fn([(2, 1)], [])

    def test_inputs_not_mutated(self):
        a = [(3, 5), (0, 2), (1, 4)]
        b = [(2, 3), (7, 8)]
        for fn in (m.union, m.intersection, m.difference):
            fn(a, b)
            self.assertEqual(a, [(3, 5), (0, 2), (1, 4)])
            self.assertEqual(b, [(2, 3), (7, 8)])
        m.normalize(a)
        self.assertEqual(a, [(3, 5), (0, 2), (1, 4)])

    def test_2000_random_pairs_and_generators(self):
        rng = random.Random(947120)
        for _ in range(2000):
            a = [
                tuple(sorted((rng.randrange(-20, 21), rng.randrange(-20, 21))))
                for _ in range(rng.randrange(15))
            ]
            b = [
                tuple(sorted((rng.randrange(-20, 21), rng.randrange(-20, 21))))
                for _ in range(rng.randrange(15))
            ]
            pa, pb = points(a), points(b)
            self.assertEqual(m.normalize(iter(a)), canonical(pa))
            for fn, expected in [
                (m.union, pa | pb),
                (m.intersection, pa & pb),
                (m.difference, pa - pb),
            ]:
                self.assertEqual(fn(iter(a), iter(b)), canonical(expected))


unittest.main(verbosity=2)
