import json
import math
import time

def normalize(data, accel_idle=7000, accel_full=22000, brake_idle=13000, brake_full=23000):
    if not isinstance(data, dict):
        raise ValueError('Expected JSON object')

    def number(key):
        value = float(data[key])
        if not math.isfinite(value):
            raise ValueError('Non-finite telemetry')
        return value

    def flag(key):
        if key not in data:
            return None
        value = data[key]
        if value is True or value == 1:
            return True
        if value is False or value == 0:
            return False
        raise ValueError('Invalid boolean ' + key)

    def percent(value):
        return max(0.0, min(100.0, value))

    source = str(data.get('pressure_source', 'unknown'))

    if 'accel_raw' in data:
        pressure = percent((number('accel_raw') - accel_idle) * 100 / (accel_full - accel_idle))
        source = 'raw'
    elif 'accel_level' in data:
        maximum = float(data.get('accel_level_max', 5))
        if not math.isfinite(maximum) or maximum <= 0:
            raise ValueError('Invalid accelerator level range')
        pressure = percent(number('accel_level') * 100 / maximum)
        source = 'level'
    else:
        pressure = percent(number('pressure'))

    if 'brake_raw' in data:
        brake = percent((number('brake_raw') - brake_idle) * 100 / (brake_full - brake_idle))
    elif 'brake_percent' in data:
        brake = percent(number('brake_percent'))
    elif 'brake_level' in data:
        maximum = float(data.get('brake_level_max', 4))
        if not math.isfinite(maximum) or maximum <= 0:
            raise ValueError('Invalid brake level range')
        brake = percent(number('brake_level') * 100 / maximum)
    else:
        brake = 0.0

    sensor_ok = flag('sensor_ok')
    if sensor_ok is False:
        pressure = brake = 0.0

    brake_active = flag('brake_active')
    if brake_active is None and any(k in data for k in ('brake_raw', 'brake_percent', 'brake_level')):
        brake_active = brake > 0 or ('brake_level' in data and number('brake_level') > 0)
    if sensor_ok is False:
        brake_active = None

    reverse = flag('reverse')
    if reverse is None and 'gear' in data:
        if data['gear'] not in ('D', 'R'):
            raise ValueError('Invalid gear')
        reverse = data['gear'] == 'R'

    def level(key):
        if key not in data:
            return None
        v = number(key)
        if v != int(v) or not 0 <= v <= 5:
            raise ValueError('Invalid command level')
        return int(v)

    capture_mode = data.get('capture_mode')
    if capture_mode not in (None, 'TEST', 'DEMO'):
        raise ValueError('Invalid capture mode')

    return dict(
        capture_mode=capture_mode,
        command_accel=level('command_accel'),
        command_brake=level('command_brake'),
        command_estop=flag('command_estop'),
        pressure=pressure,
        angle=max(-90, min(90, number('angle'))),
        brake=brake,
        brake_active=brake_active,
        reverse=reverse,
        drive_enabled=flag('drive_enabled'),
        estop=flag('estop') is True,
        cnn_valid=flag('cnn_valid') is True,
        source=source,
    )