"""Sends fake Tuning Telemetry packets so the recorder can be tested without BeamNG.

py test/fake_sender.py [seconds]
"""

import json
import math
import socket
import sys
import time

ADDR = ("127.0.0.1", 4445)
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)


def send(msg):
    sock.sendto(json.dumps(msg).encode(), ADDR)


def send_chunked(msg, size=60000):
    s = json.dumps(msg)
    count = math.ceil(len(s) / size)
    for i in range(count):
        send({"type": "chunk", "id": "test", "i": i + 1, "of": count, "data": s[i * size:(i + 1) * size]})


duration = float(sys.argv[1]) if len(sys.argv) > 1 else 3
corners = ["FL", "FR", "RL", "RR"]
send({"type": "meta", "vid": 1, "vehicle": "vehicles/barstow/", "sendRate": 50,
      "wheels": [{"name": c, "radius": 0.33, "wheelDir": 1} for c in corners],
      "dampers": [{"corner": c, "source": "vkTag", "restLength": 0.4} for c in corners]})
# big config to exercise chunk reassembly
send_chunked({"type": "config", "vid": 1, "model": "barstow", "inventoryId": 7,
              "parts": {f"slot_{i}": f"part_{i}" * 20 for i in range(1000)}, "vars": {"$arb_spring_R": 44500}})

t = 0.0
seq = 0
end = time.time() + duration
while time.time() < end:
    seq += 1
    send({"type": "frame", "seq": seq, "t": round(t, 3), "spd": 20.0, "rpm": 4000, "gear": "2",
          "w": [{"n": c, "slip": 0.1} for c in corners], "d": [{"n": c, "c": 10 * math.sin(t)} for c in corners]})
    if seq == 50:
        send({"type": "mark", "vid": 1, "n": 1, "t": round(t, 3), "seq": seq})
    t += 0.02
    time.sleep(0.02)
print(f"sent {seq} frames")
