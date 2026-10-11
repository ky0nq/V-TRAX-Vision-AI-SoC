# Verify vehicle target control command behavior
import sys
from pathlib import Path
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from motion_model import MotionModel


class MotionTests(unittest.TestCase):
    def test_each_level_reaches_its_target_and_stays_there(self):
        for level, target in enumerate(MotionModel.TARGET_SPEED[1:], 1):
            m = MotionModel()
            for _ in range(800):
                m.step(level, 0, .025)
                self.assertLessEqual(m.speed, target)
            self.assertAlmostEqual(m.speed, target)
            self.assertAlmostEqual(m.command_percent, target / 255 * 100)
            self.assertEqual(m.motor_output, int(target) * 230 // 255)

    def test_lower_level_decelerates_without_overshooting(self):
        m = MotionModel()
        m.speed = 255
        self.assertEqual(m.step(1, 0, .5), 215)
        for _ in range(100):
            m.step(1, 0, .025)
        self.assertEqual(m.speed, 67)

    def test_brake_priority_rates_and_coast(self):
        for level, rate in enumerate(MotionModel.BRAKE[1:], 1):
            m = MotionModel()
            m.speed = 255
            self.assertAlmostEqual(m.step(5, level, .1), 255 - rate * .1)
        m = MotionModel()
        m.speed = 100
        self.assertAlmostEqual(m.step(0, 0, 1), 89.8)
        m.step(0, 5, 5)
        self.assertEqual(m.speed, 0)

    def test_stop_and_direction_interlock(self):
        m = MotionModel()
        m.speed = 100
        self.assertEqual(m.step(5, 0, 1, stopped=True), 0)
        m.step(5, 0, 1)
        self.assertEqual(m.step(5, 0, 1, reverse=True), 0)
        self.assertTrue(m.direction_interlock)
        self.assertEqual(m.step(5, 0, 1, reverse=True), 0)
        m.step(0, 0, .025, reverse=True)
        self.assertFalse(m.direction_interlock)
        self.assertEqual(m.step(1, 0, 1, reverse=True), 50)
        self.assertEqual(m.step(1, 0, .1, active=False, reverse=True), 0)


if __name__ == "__main__":
    unittest.main()
