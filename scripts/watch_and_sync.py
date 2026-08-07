#!/usr/bin/env python3
import os
import sys
import time
import subprocess
from pathlib import Path

REPO_DIR = Path(__file__).resolve().parent.parent
AUTO_SYNC_SCRIPT = REPO_DIR / "scripts" / "auto_sync.sh"

IGNORE_DIRS = {".git", ".build", ".venv", "venv", "__pycache__", "dist", "DerivedData", ".claude"}
IGNORE_EXTS = {".tmp", ".swp", ".DS_Store", ".log"}

def get_dir_mtime(root_dir):
    max_mtime = 0
    for root, dirs, files in os.walk(root_dir):
        # 제외할 디렉토리 필터링
        dirs[:] = [d for d in dirs if d not in IGNORE_DIRS and not d.startswith(".")]
        for f in files:
            if any(f.endswith(ext) for ext in IGNORE_EXTS) or f.startswith("."):
                continue
            filepath = os.path.join(root, f)
            try:
                mtime = os.path.getmtime(filepath)
                if mtime > max_mtime:
                    max_mtime = mtime
            except OSError:
                pass
    return max_mtime

def main():
    print(f"[*] Starting VideoLingo auto-sync watcher in {REPO_DIR}")
    last_mtime = get_dir_mtime(REPO_DIR)

    while True:
        try:
            time.sleep(3)
            current_mtime = get_dir_mtime(REPO_DIR)
            if current_mtime > last_mtime:
                last_mtime = current_mtime
                print("[*] File change detected! Waiting 5s debounce...")
                time.sleep(5)
                # 디바운스 완료 후 mtime 최신화
                last_mtime = get_dir_mtime(REPO_DIR)
                print("[*] Running auto_sync.sh...")
                subprocess.run([str(AUTO_SYNC_SCRIPT)], cwd=str(REPO_DIR))
        except KeyboardInterrupt:
            print("[*] Watcher stopped.")
            break
        except Exception as e:
            print(f"[!] Error in watcher: {e}")
            time.sleep(5)

if __name__ == "__main__":
    main()
