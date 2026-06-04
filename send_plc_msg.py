#!/usr/bin/env python3
import socket
import time

class PLCSimulator:
    def __init__(self, host="127.0.0.1"):
        self.host = host
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

    def _send(self, data, port):
        self.sock.sendto(data, (self.host, port))
        print(f"Sent {len(data)} bytes to {self.host}:{port}")

    def send_nov_eye_status(self, arc_on=True, major=0, minor=2):
        """Size: 200 bytes. Version at offset 160/161."""
        size = 200
        msg = bytearray(size)
        
        # Header data from noveye_status_parser.rs
        header = bytes.fromhex("000208287aae5707")
        msg[0:len(header)] = header
        
        # Byte 8: Arc status (0x0b for ON, 0x0a for OFF)
        msg[8] = 0x0b if arc_on else 0x0a 
        
        # Version Offset: 160/161 to satisfy receiver check
        msg[160] = major
        msg[161] = minor
        
        self._send(msg, 8404)

    def send_nov_eye_data(self, major=0, minor=7):
        """Size: 300 bytes. Version at 0/1."""
        size = 300
        msg = bytearray(size)
        
        # Version Offset: 0/1 for Eye Data
        msg[0] = major
        msg[1] = minor
        
        # No run_id appended to maintain strict 300-byte size
        self._send(msg, 8408)

    def send_nov_data(self, arc_on=True, major=1, minor=19):
        """Size: 500 bytes. Version at 160/161."""
        size = 500
        msg = bytearray(size)
        
        # Byte 0: Arc status (0x01 for ON, 0x00 for OFF)
        msg[0] = 0x01 if arc_on else 0x00
        
        # Version Offset: 160/161
        msg[160] = major
        msg[161] = minor
        
        self._send(msg, 8400)

if __name__ == "__main__":
    sim = PLCSimulator()
    
    print("--- Starting PLC Message Simulation ---")
    
    # 1. Status Message (200 bytes)
    print("Sending NovEye Status (Arc ON, Version 0.2)...")
    sim.send_nov_eye_status(arc_on=True, major=0, minor=2)
    time.sleep(1)
    
    # 2. Eye Data Message (300 bytes)
    print("Sending NovEye Data (Version 0.7)...")
    sim.send_nov_eye_data(major=0, minor=7)
    time.sleep(1)
    
    # 3. Standard Data Message (500 bytes)
    print("Sending Nov Data (Arc OFF, Version 1.19)...")
    sim.send_nov_data(arc_on=False, major=1, minor=19)
    
    print("--- Simulation Complete ---")