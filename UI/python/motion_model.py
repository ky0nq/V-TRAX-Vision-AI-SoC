# Estimate the supplied ESP32 controller's command state, not measured km/h.

class MotionModel:
    TARGET_SPEED = (0.0, 67.0, 100.0, 139.0, 188.0, 255.0)
    SPEED_MAX = 255.0
    RISE_RATE = 50.0
    FALL_RATE = 80.0
    BRAKE = (0.0, 25.5, 45.9, 76.5, 255.0, 318.75)
    COAST = 10.2
    MOTOR_COMMAND_MIN = 60
    PWM_MAX = 230

    def __init__(self):
        self.speed = 0.0
        self.reverse = False
        self.direction_interlock = False

    @property
    def command_percent(self):
        return max(0.0, min(100.0, self.speed * 100.0 / self.SPEED_MAX))

    @property
    def motor_output(self):
        # test code
        if self.speed <= 0:
            return 0
        command = max(self.MOTOR_COMMAND_MIN, min(255, int(self.speed + 0.5)))
        return command * self.PWM_MAX // 255

    def step(self, accel_level, brake_level, dt, active=True, stopped=False, reverse=False):
        a = max(0, min(5, int(accel_level)))
        b = max(0, min(5, int(brake_level)))
        dt = max(0.0, dt)
        if reverse != self.reverse:
            self.reverse = reverse
            self.direction_interlock = True
            self.speed = 0.0
        if not active or stopped:
            self.speed = 0.0
        elif self.direction_interlock:
            self.speed = 0.0
            if a == 0:
                self.direction_interlock = False
        elif b:
            self.speed = max(0.0, self.speed - self.BRAKE[b] * dt)
        elif a:
            target = self.TARGET_SPEED[a]
            rate = self.RISE_RATE if self.speed < target else self.FALL_RATE
            if self.speed < target:
                self.speed = min(target, self.speed + rate * dt)
            else:
                self.speed = max(target, self.speed - rate * dt)
        else:
            self.speed = max(0.0, self.speed - self.COAST * dt)
        self.speed = max(0.0, min(self.SPEED_MAX, self.speed))
        return self.speed
