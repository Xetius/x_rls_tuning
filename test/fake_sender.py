"""Pretends to be BeamNG with the Tuning Telemetry mod, so the recorder can be tested
without the game: sends frames, a meta and a (chunked) config, and answers the
recorder's commands on the control port (setMode -> modeAck, mark -> mark).

py test/fake_sender.py [seconds]
"""

import json
import math
import socket
import sys
import time

ADDR = ("127.0.0.1", 4445)
CONTROL = ("127.0.0.1", 4446)
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
control = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
control.bind(CONTROL)
control.setblocking(False)


def send(msg):
    sock.sendto(json.dumps(msg).encode(), ADDR)


def send_chunked(msg, size=60000):
    s = json.dumps(msg)
    count = math.ceil(len(s) / size)
    for i in range(count):
        send({"type": "chunk", "id": "test", "i": i + 1, "of": count, "data": s[i * size:(i + 1) * size]})


duration = float(sys.argv[1]) if len(sys.argv) > 1 else 3
corners = ["FL", "FR", "RL", "RR"]
mode = "all"
send({"type": "meta", "vid": 1, "role": "driver", "mode": mode, "vehicle": "vehicles/barstow/", "sendRate": 50,
      "wheels": [{"name": c, "radius": 0.33, "wheelDir": 1} for c in corners],
      "dampers": [{"corner": c, "source": "vkTag", "restLength": 0.4} for c in corners],
      "modeDevices": [{"name": "rangebox", "mode": "high", "modes": ["high", "low"]}]})
# big config to exercise chunk reassembly
send_chunked({"type": "config", "vid": 1, "role": "driver", "model": "barstow", "career": "rls", "saveSlot": "Test",
              "inventoryId": 7, "parts": {f"slot_{i}": f"part_{i}" * 20 for i in range(1000)},
              "vars": {"$arb_spring_R": 44500}})
send({"type": "config", "vid": 2, "role": "trailer", "model": "tanker", "career": "rls", "parts": {}, "vars": {}})

t = 0.0
seq = 0
marks = 0
end = time.time() + duration
while time.time() < end:
    while True:
        try:
            cmd = json.loads(control.recv(65535))
        except (BlockingIOError, ConnectionResetError):
            break
        if cmd.get("type") == "setMode" and cmd.get("mode") != mode:
            mode = cmd["mode"]
            send({"type": "modeAck", "mode": mode})
            send({"type": "mode", "vid": 1, "role": "driver", "mode": mode, "rate": 50, "t": round(t, 3)})
        elif cmd.get("type") == "mark":
            marks += 1
            send({"type": "mark", "vid": 1, "n": marks, "t": round(t, 3), "seq": seq})
    seq += 1
    send({"type": "frame", "vid": 1, "seq": seq, "t": round(t, 3), "spd": 20.0 + t, "rpm": 4000, "gear": "2",
          "hdg": (t * 10) % 360, "slipAng": 5 * math.sin(t), "pm": {"rangebox": "high"},
          "w": [{"n": c, "slip": 0.1} for c in corners], "d": [{"n": c, "c": 10 * math.sin(t)} for c in corners]})
    if seq % 5 == 0:
        send({"type": "frame", "vid": 2, "role": "trailer", "seq": seq, "t": round(t, 3), "spd": 20.0 + t})
    if seq == 50:
        marks += 1
        send({"type": "mark", "vid": 1, "n": marks, "t": round(t, 3), "seq": seq})
    t += 0.02
    time.sleep(0.02)
print(f"sent {seq} frames, {marks} marks, final mode {mode}")
