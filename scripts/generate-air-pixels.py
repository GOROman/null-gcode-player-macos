"""Preview experiment only: anchored, nonplanar pixel heart. Not a validated machine job."""
from pathlib import Path
import math

bitmap = ['.##.##.', '#######', '#######', '.#####.', '..###..', '...#...']
lines = ['; AIR PIXEL HEART - PREVIEW ONLY',
         '; Not validated on H3C. No homing, heating or machine start/end sequence.',
         '; Each pixel is a coiled bead connected to a continuous vertical stem.',
         '; Cooling dwell is illustrative; viewer currently uses motion time only.',
         '; filament_colour = #EF3159', '; printable_area = 0x0,300x0,300x300,0x300',
         'G21', 'G90', 'M83', 'T0', '; CHANGE_LAYER']
pos = (0, 0, 0)
width = height = .4

def profile(w, h):
    global width, height
    width, height = w, h
    lines.extend([f'; LINE_WIDTH: {w}', f'; LAYER_HEIGHT: {h}'])

def move(x, y, z, deposit=False, speed=600):
    global pos
    length = math.dist(pos, (x, y, z))
    e = length * width * height * math.pi / 4 / (math.pi * (1.75 / 2)**2)
    lines.append(f'G1 X{x:.4f} Y{y:.4f} Z{z:.4f}' + (f' E{e:.5f}' if deposit else '') + f' F{speed}')
    pos = (x, y, z)

# Broad rail joins all seven stems to the build plate.
profile(.48, .2)
for layer in range(3):
    z = .2 * (layer + 1)
    for row in range(9):
        y = 148 + row * .45
        a, b = (130, 170) if row % 2 == 0 else (170, 130)
        move(a, y, z)
        move(b, y, z, True, 900)

# All columns grow together in 0.3 mm height bands. The head never descends
# alongside a previously completed tall column. XY transfers happen above all
# deposited material, then descend to that column's existing endpoint.
ends = [(132 + col * 6, 150, .6) for col in range(7)]
steps = math.ceil((36.2 - .6) / .3)
for step in range(steps):
    bottom = .6 + step * .3
    top = min(36.2, bottom + .3)
    lines.append(f'; HEIGHT BAND {step + 1}: {bottom:.2f} to {top:.2f} mm')
    for col in range(7):
        x, y = 132 + col * 6, 150
        active = [len(bitmap) - 1 - r for r in range(len(bitmap)) if bitmap[r][col] == '#']
        if bottom >= 5 + max(active) * 6 + 1.2:
            continue
        last = ends[col]
        move(pos[0], pos[1], top + 2)
        move(last[0], last[1], top + 2)
        move(*last)
        center = next((5 + level * 6 for level in active
                       if bottom < 5 + level * 6 + 1.2 and top > 5 + level * 6 - 1.2), None)
        if center is None:
            profile(.32, .32)
            move(x, y, top, True, 60)
        else:
            profile(.45, .3)
            for i in range(1, 19):
                z = bottom + (top - bottom) * i / 18
                t = max(0, min(1, (z - (center - 1.2)) / 2.4))
                radius = 1.25 * math.sin(math.pi * t)
                angle = t * math.tau * 8
                move(x + radius * math.cos(angle), y + radius * math.sin(angle), z, True, 180)
        ends[col] = pos
    lines.extend(['M400', 'G4 P1500 ; illustrative cooling pause'])
move(pos[0], pos[1], 44)
move(180, 150, 44)
lines.extend(['M400', '; END OF PREVIEW EXPERIMENT'])
path = Path(__file__).resolve().parent.parent / 'samples/air-pixel-heart.gcode'
path.write_text('\n'.join(lines) + '\n')
print(path)
print('Pixels:', sum(row.count('#') for row in bitmap))
